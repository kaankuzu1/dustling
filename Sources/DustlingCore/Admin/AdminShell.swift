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
            return .failed(reason: error.localizedDescription)
        }
    }

    /// The AppleScript source. `\` and `"` are escaped so neither the script nor the prompt can end
    /// the string early; line breaks and tabs stay literal, which AppleScript keeps as they are.
    static func appleScript(script: String, prompt: String, privileged: Bool) -> String {
        guard privileged else {
            return "do shell script \(literal(script)) without altering line endings"
        }
        return "do shell script \(literal(script)) with prompt \(literal(prompt))"
            + " with administrator privileges without altering line endings"
    }

    private static func literal(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// osascript prints the script's output followed by one line break of its own, which is dropped.
    /// A cancelled password box is error -128 (its message is localized, the number is not).
    static func result(from command: CommandResult) -> AdminShellResult {
        if command.status == 0 {
            var output = command.stdout
            if output.unicodeScalars.last == "\n" { output.unicodeScalars.removeLast() }
            return .finished(output: output)
        }
        let message = command.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("(-128)") || message.contains("User canceled") {
            return .cancelled
        }
        return .failed(reason: message.isEmpty ? "osascript stopped with status \(command.status)" : message)
    }
}
