import AppKit
import Foundation

public protocol RunningAppsProviding: Sendable {
    func isRunning(_ app: InstalledApp) -> Bool
}

/// Matches running applications by bundle location, so a same-named app elsewhere doesn't block.
public struct WorkspaceRunningApps: RunningAppsProviding {
    public init() {}

    public func isRunning(_ app: InstalledApp) -> Bool {
        let target = app.url.standardizedFileURL
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL == target
        }
    }
}

public enum UninstallError: Error, Equatable {
    case appIsRunning(String)
}

/// Removes an app and the leftovers the user selected. Everything goes to the Trash through
/// `CleanupRunner`; admin-only leftovers are recorded as "needs admin" and never attempted.
public struct Uninstaller: Sendable {
    private let runner: CleanupRunner
    private let commands: CommandRunning
    private let running: RunningAppsProviding
    private let environment: SystemEnvironment

    public init(
        runner: CleanupRunner, commands: CommandRunning, running: RunningAppsProviding,
        environment: SystemEnvironment
    ) {
        self.runner = runner
        self.commands = commands
        self.running = running
        self.environment = environment
    }

    /// `leftovers` is the set the user selected; it is not re-filtered here.
    public func uninstall(
        _ app: InstalledApp,
        leftovers: [Leftover],
        onItem: @Sendable (URL, DeletionOutcome) -> Void
    ) async throws -> RunRecord {
        if running.isRunning(app) { throw UninstallError.appIsRunning(app.displayName) }

        let userLeftovers = leftovers.filter { !$0.requiresAdmin }
        let adminLeftovers = leftovers.filter { $0.requiresAdmin }

        var extra: [JournalEntry] = []
        for agent in userLeftovers where agent.kind == .launchAgent {
            if let failure = unload(agent.url) { extra.append(failure) }
        }
        for leftover in adminLeftovers {
            extra.append(JournalEntry(
                originalPath: leftover.url.path(percentEncoded: false),
                bytes: leftover.bytes, outcome: .needsAdmin))
        }

        var roots = environment.applicationDirectories
        for leftover in userLeftovers {
            let parent = leftover.url.deletingLastPathComponent()
            if !roots.contains(parent) { roots.append(parent) }
        }

        return await runner.run(
            [app.url] + userLeftovers.map(\.url),
            kind: .uninstall(appName: app.displayName),
            allowedRoots: roots,
            extraEntries: extra,
            onItem: onItem)
    }

    /// Returns a failure entry, or nil when the agent was unloaded (or wasn't loaded at all).
    private func unload(_ plist: URL) -> JournalEntry? {
        let path = plist.path(percentEncoded: false)
        func failure(_ reason: String) -> JournalEntry {
            JournalEntry(originalPath: path, bytes: 0, outcome: .failed(reason: "could not unload: \(reason)"))
        }
        do {
            let result = try commands.run("/bin/launchctl", ["bootout", "gui/\(environment.userID)", path])
            if result.status == 0 { return nil }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let notLoaded = ["No such process", "Could not find specified service"]
            if notLoaded.contains(where: { stderr.contains($0) }) { return nil }
            return failure(stderr)
        } catch {
            return failure(error.localizedDescription)
        }
    }
}
