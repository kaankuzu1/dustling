import Foundation

/// Stops a user launch agent before its plist moves, with `launchctl bootout gui/<uid> <plist>`.
///
/// An agent that isn't loaded has nothing to stop, which is not a failure. launchctl says so in
/// different ways: "No such process" or "Could not find specified service" on older systems, and on
/// macOS 26 and later a bare "Boot-out failed: 5: Input/output error" when booting out by path. For
/// that last, vague error the agent's label is read from the plist and `launchctl print` asks whether
/// it is loaded at all; only a loaded agent that won't stop is a failure.
public enum LaunchAgentBootout {
    public enum Result: Equatable, Sendable {
        case stopped
        case notLoaded
        /// launchctl's own words, or why it couldn't run.
        case failed(String)
    }

    static let notLoadedMessages = ["No such process", "Could not find specified service"]
    static let launchctl = "/bin/launchctl"

    public static func run(plist: URL, userID: uid_t, commands: any CommandRunning) -> Result {
        let path = plist.path(percentEncoded: false)
        let result: CommandResult
        do {
            result = try commands.run(launchctl, ["bootout", "gui/\(userID)", path])
        } catch {
            return .failed(error.localizedDescription)
        }
        if result.status == 0 { return .stopped }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if notLoadedMessages.contains(where: { stderr.contains($0) }) { return .notLoaded }
        if let label = label(of: plist), !isLoaded(label, userID: userID, commands: commands) { return .notLoaded }
        return .failed(stderr)
    }

    /// True unless `launchctl print` says the service isn't in the user's domain (exit 113, "Could not
    /// find service"). Any other answer, or a launchctl that can't run, counts as loaded, so the original
    /// failure is reported.
    static func isLoaded(_ label: String, userID: uid_t, commands: any CommandRunning) -> Bool {
        guard let result = try? commands.run(launchctl, ["print", "gui/\(userID)/\(label)"]) else { return true }
        let notFound = result.status == 113
            || (result.status != 0 && (result.stderr + result.stdout).contains("Could not find service"))
        return !notFound
    }

    static func label(of plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let label = dict["Label"] as? String, !label.isEmpty
        else { return nil }
        return label
    }
}
