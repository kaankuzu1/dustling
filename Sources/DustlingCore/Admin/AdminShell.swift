import Foundation

public enum AdminShellResult: Equatable, Sendable {
    /// The script ran; `output` is everything it printed.
    case finished(output: String)
    /// The user closed the password box.
    case cancelled
    /// Nothing ran, or the script could not finish.
    case failed(reason: String)
}

/// Runs one shell script as root after asking for the Mac password. Injectable so tests never
/// put a password box on the screen.
public protocol AdminShell: Sendable {
    func run(script: String, prompt: String) -> AdminShellResult
}

/// Asks with the standard macOS password box: `do shell script … with administrator privileges`,
/// run by `/usr/bin/osascript` as a child process (never `NSAppleScript`, which must run on the main
/// thread and would freeze the window while files move). The password covers exactly this one
/// script (Apple TN2065), so callers put every step of one user action into one script.
public struct OsascriptAdminShell: AdminShell {
    private let privileged: Bool
    private let commands = ProcessCommandRunner()
    /// Shared by every copy of this shell (an `AdminMover` holds one).
    private let children = AdminChildren()

    /// The whole environment osascript (and so the script's shell) gets. Nothing is inherited from
    /// Dustling: /bin/sh is bash, which runs code from variables like `BASH_FUNC_name%%`,
    /// `SHELLOPTS` and `PS4` before the script's first line. Non-ASCII paths work without a locale.
    static let childEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    public init() {
        self.init(privileged: true)
    }

    /// `privileged: false` runs the same script as the current user without a password box.
    /// Only for the one test that checks the osascript round trip.
    init(privileged: Bool) {
        self.privileged = privileged
    }

    public func run(script: String, prompt: String) -> AdminShellResult {
        guard !children.isStopped else { return .failed(reason: Self.stoppedReason) }
        let source = Self.appleScript(script: script, prompt: prompt, privileged: privileged)
        var launched: Process?
        defer { if let launched { children.remove(launched) } }
        do {
            let command = try commands.run(
                "/usr/bin/osascript", ["-e", source], environment: Self.childEnvironment,
                started: { process in
                    launched = process
                    children.add(process)
                })
            // Stopped by `terminateRunning`, unless it had finished just before.
            if command.status != 0, children.isStopped { return .failed(reason: Self.stoppedReason) }
            return Self.result(from: command)
        } catch {
            return Self.result(from: error)
        }
    }

    /// Why a password step ended (or never started) after `terminateRunning`.
    public static let stoppedReason = "Dustling stopped before the password step finished."

    /// Ends this shell's work for good: every `osascript` it started that is still running is
    /// terminated (SIGTERM; a password box it shows goes with it, so an answer given after Dustling
    /// quit can't move anything), and every later `run` returns `.failed(reason: stoppedReason)`
    /// without starting one. A step that ran this way is `.failed`, not `.cancelled`: the box may
    /// already have been answered and the script running as root, so nothing can say that nothing
    /// ran. Call it when the app terminates. Safe from any thread; copies of this shell share it.
    public func terminateRunning() {
        children.stopAll()
    }

    /// How many `osascript` children of this shell are running, and how many it ever started (tests).
    var runningCount: Int { children.count }
    var startedCount: Int { children.started }

    /// The script did not fit in one command line (the system's argument size limit).
    public static let tooManyItemsReason = "Too many items for one password request. Try again with fewer items."

    /// The AppleScript source. `\` and `"` are escaped so neither the script nor the prompt can end
    /// the string early; line breaks and tabs stay literal, which AppleScript keeps as they are.
    /// Escaping works on unicode scalars: a `"` or `\` followed by a combining mark is one Swift
    /// Character, and Character-based replacing would leave it unescaped.
    static func appleScript(script: String, prompt: String, privileged: Bool) -> String {
        guard privileged else {
            return "do shell script \(literal(script)) without altering line endings"
        }
        return "do shell script \(literal(script)) with prompt \(literal(prompt))"
            + " with administrator privileges without altering line endings"
    }

    static func literal(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append("\"")
        for scalar in text.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { scalars.append("\\") }
            scalars.append(scalar)
        }
        scalars.append("\"")
        return String(scalars)
    }

    /// Why nothing ran when macOS turned the password down (a wrong password three times, or an
    /// account that can't approve it).
    public static let passwordNotAcceptedReason = "Your Mac password wasn't accepted."

    /// The authorization errors macOS reports when it turns the password down: denied (-60005),
    /// canceled by the system (-60006), no interaction allowed (-60007).
    private static let authorizationFailures = ["(-60005)", "(-60006)", "(-60007)"]

    /// osascript prints the script's output followed by one line break of its own, which is dropped.
    /// A cancelled password box is error -128, which osascript puts at the very end of its message
    /// (the message itself is localized, the number is not); so are the authorization errors, which
    /// become `passwordNotAcceptedReason`. Any other message loses osascript's position prefix
    /// ("0:2318: execution error: "), which means nothing to the people reading it.
    static func result(from command: CommandResult) -> AdminShellResult {
        if command.status == 0 {
            var output = command.stdout
            if output.unicodeScalars.last == "\n" { output.unicodeScalars.removeLast() }
            return .finished(output: output)
        }
        let message = command.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasSuffix("(-128)") { return .cancelled }
        if message.contains(argumentListTooLong) { return .failed(reason: tooManyItemsReason) }
        if authorizationFailures.contains(where: { message.hasSuffix($0) }) {
            return .failed(reason: passwordNotAcceptedReason)
        }
        let plain = withoutPosition(message)
        return .failed(reason: plain.isEmpty ? "osascript stopped with status \(command.status)" : plain)
    }

    /// `message` without osascript's leading "<start>:<end>: " and the "execution error: " (or
    /// "syntax error: ") after it.
    static func withoutPosition(_ message: String) -> String {
        guard let position = message.firstMatch(of: /^[0-9]+:[0-9]+:[ ]*/) else { return message }
        var rest = message[position.range.upperBound...]
        if let kind = rest.firstMatch(of: /^(execution|syntax) error:[ ]*/) { rest = rest[kind.range.upperBound...] }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// osascript could not even be started. E2BIG means the script was too long for one command line.
    static func result(from error: any Error) -> AdminShellResult {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(E2BIG) {
                return .failed(reason: tooManyItemsReason)
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let description = error.localizedDescription
        return .failed(reason: description.contains(argumentListTooLong) ? tooManyItemsReason : description)
    }

    private static let argumentListTooLong = "Argument list too long"
}

/// The `osascript` processes an `OsascriptAdminShell` started and hasn't seen end, and whether it was
/// stopped. A process registered after `stopAll` (it launched while stopping) is terminated at once.
final class AdminChildren: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]
    private var stopped = false
    private var launched = 0

    var isStopped: Bool { lock.withLock { stopped } }
    var count: Int { lock.withLock { running.count } }
    var started: Int { lock.withLock { launched } }

    func add(_ process: Process) {
        lock.withLock {
            launched += 1
            if stopped {
                process.terminate()
            } else {
                running[ObjectIdentifier(process)] = process
            }
        }
    }

    func remove(_ process: Process) {
        _ = lock.withLock { running.removeValue(forKey: ObjectIdentifier(process)) }
    }

    func stopAll() {
        lock.withLock {
            stopped = true
            for process in running.values where process.isRunning { process.terminate() }
        }
    }
}
