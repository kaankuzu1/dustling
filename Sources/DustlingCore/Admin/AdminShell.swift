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
    private let commands: any CommandRunning

    public init() {
        self.init(privileged: true)
    }

    /// `privileged: false` runs the same script as the current user without a password box.
    /// Only for the one test that checks the osascript round trip.
    init(privileged: Bool) {
        self.privileged = privileged
        self.commands = ProcessCommandRunner()
    }

    public func run(script: String, prompt: String) -> AdminShellResult {
        let source = Self.appleScript(script: script, prompt: prompt, privileged: privileged)
        do {
            return Self.result(from: try commands.run("/usr/bin/osascript", ["-e", source]))
        } catch {
            return Self.result(from: error)
        }
    }

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

    /// osascript prints the script's output followed by one line break of its own, which is dropped.
    /// A cancelled password box is error -128, which osascript puts at the very end of its message
    /// (the message itself is localized, the number is not).
    static func result(from command: CommandResult) -> AdminShellResult {
        if command.status == 0 {
            var output = command.stdout
            if output.unicodeScalars.last == "\n" { output.unicodeScalars.removeLast() }
            return .finished(output: output)
        }
        let message = command.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasSuffix("(-128)") { return .cancelled }
        if message.contains(argumentListTooLong) { return .failed(reason: tooManyItemsReason) }
        return .failed(reason: message.isEmpty ? "osascript stopped with status \(command.status)" : message)
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
