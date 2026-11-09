import AppKit
import Foundation

public protocol RunningAppsProviding: Sendable {
    func isRunning(_ app: InstalledApp) -> Bool
}

/// Matches running applications by bundle location, so a same-named app elsewhere doesn't block.
/// A symlinked app also counts as running when its target is.
public struct WorkspaceRunningApps: RunningAppsProviding {
    public init() {}

    public func isRunning(_ app: InstalledApp) -> Bool {
        let targets = Set([app.url, app.linkTarget].compactMap { $0?.resolvingSymlinksInPath().standardizedFileURL.path })
        return NSWorkspace.shared.runningApplications.contains {
            guard let bundle = $0.bundleURL, !$0.isTerminated else { return false }
            return targets.contains(bundle.resolvingSymlinksInPath().standardizedFileURL.path)
        }
    }
}

public enum UninstallError: Error, Equatable {
    case appIsRunning(String)
}

/// Removes an app and the leftovers the user selected. Everything goes to the Trash through
/// `CleanupRunner`; admin-only leftovers are recorded as "needs admin" and never attempted.
///
/// The app bundle moves first. Leftovers are only touched once the app itself is in the Trash, so a
/// refused or failed app never loses its settings and data. The allowed roots are fixed (the
/// application folders and the leftover locations the finder declares), never derived from input.
public struct Uninstaller: Sendable {
    static let keptReason = "kept because the app itself was not removed"

    private let runner: CleanupRunner
    private let commands: CommandRunning
    private let running: RunningAppsProviding
    private let environment: SystemEnvironment

    /// The bootout guard is the runner's own `ProtectedPaths`, so a user-excluded launch agent is
    /// neither booted out nor trashed.
    public init(
        runner: CleanupRunner, commands: CommandRunning, running: RunningAppsProviding,
        environment: SystemEnvironment
    ) {
        self.runner = runner
        self.commands = commands
        self.running = running
        self.environment = environment
    }

    /// `leftovers` is the set the user selected; it is not re-filtered here, but each one must be a
    /// direct child of a declared leftover location (and not a declared location itself) or it is
    /// skipped as outside the cleanup area. `skipped` are leftovers the caller decided not to touch
    /// (e.g. without Full Disk Access): they are never attempted and are recorded here as
    /// `.skipped(reason: skipReason)`, so a caller can't put anything else in the record.
    public func uninstall(
        _ app: InstalledApp,
        leftovers: [Leftover],
        skipped: [Leftover] = [],
        skipReason: String = "skipped by request",
        onItem: @escaping @Sendable (URL, DeletionOutcome) -> Void
    ) async throws -> RunRecord {
        // Moving, measuring and unloading block, so they run on the file-work queue, never on the
        // cooperative pool. An uninstall isn't cancellable: once the app has moved, its leftovers follow.
        try await FileWork.run {
            try uninstallBlocking(app, leftovers: leftovers, skipped: skipped, skipReason: skipReason, onItem: onItem)
        }
    }

    private func uninstallBlocking(
        _ app: InstalledApp,
        leftovers: [Leftover],
        skipped: [Leftover],
        skipReason: String,
        onItem: (URL, DeletionOutcome) -> Void
    ) throws -> RunRecord {
        if running.isRunning(app) { throw UninstallError.appIsRunning(app.displayName) }

        let startedAt = Date()
        let kind = RunKind.uninstall(appName: app.displayName)
        let skippedPaths = Set(skipped.map { Self.key($0.url) })
        let leftovers = leftovers.filter { !skippedPaths.contains(Self.key($0.url)) }
        let skipEntries = skipped.map {
            JournalEntry(originalPath: $0.url.path(percentEncoded: false), bytes: $0.bytes,
                         outcome: .skipped(reason: skipReason))
        }
        let locations = LeftoverFinder.locationDirectories(environment)
        let roots = environment.applicationDirectories + locations

        let appEntry = runner.attempt(app.url, allowedRoots: roots)
        var entries = [appEntry]
        onItem(app.url, appEntry.outcome)

        guard case .movedToTrash = appEntry.outcome else {
            for leftover in leftovers {
                let outcome = DeletionOutcome.skipped(reason: Self.keptReason)
                entries.append(JournalEntry(
                    originalPath: leftover.url.path(percentEncoded: false), bytes: leftover.bytes, outcome: outcome))
                onItem(leftover.url, outcome)
            }
            return runner.finish(entries + skipEntries, kind: kind, startedAt: startedAt)
        }

        let locationPaths = Set(locations.map { Self.key($0) })
        /// A leftover is a direct child of a declared location and never a declared location itself
        /// (e.g. steamapps/common or Preferences/ByHost, whose parents are declared locations too).
        func isLeftoverShaped(_ url: URL) -> Bool {
            locationPaths.contains(Self.key(url.deletingLastPathComponent())) && !locationPaths.contains(Self.key(url))
        }
        let userLeftovers = leftovers.filter { !$0.requiresAdmin }
        let adminLeftovers = leftovers.filter { $0.requiresAdmin }

        var extra: [JournalEntry] = []
        let agentsDirectory = environment.userLibrary.appending(path: "LaunchAgents", directoryHint: .isDirectory)
        let guardPaths = runner.protectedPaths
        for agent in userLeftovers where agent.kind == .launchAgent {
            // Only agents that really live in ~/Library/LaunchAgents are ever booted out.
            guard guardPaths.verdict(for: agent.url, allowedRoots: [agentsDirectory]) == .allowed,
                  isLeftoverShaped(agent.url)
            else { continue }
            if let failure = unload(agent.url) { extra.append(failure) }
        }
        for leftover in userLeftovers {
            let entry: JournalEntry
            if isLeftoverShaped(leftover.url) {
                entry = runner.attempt(leftover.url, allowedRoots: roots)
            } else {
                entry = JournalEntry(
                    originalPath: leftover.url.path(percentEncoded: false), bytes: leftover.bytes,
                    outcome: .skipped(reason: "outside the cleanup area"))
            }
            entries.append(entry)
            onItem(leftover.url, entry.outcome)
        }
        for leftover in adminLeftovers {
            extra.append(JournalEntry(
                originalPath: leftover.url.path(percentEncoded: false),
                bytes: leftover.bytes, outcome: .needsAdmin))
        }
        return runner.finish(entries + skipEntries + extra, kind: kind, startedAt: startedAt)
    }

    private static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Returns a failure entry, or nil when the agent was unloaded (or wasn't loaded at all).
    private func unload(_ plist: URL) -> JournalEntry? {
        let path = plist.path(percentEncoded: false)
        func failure(_ reason: String) -> JournalEntry {
            JournalEntry(originalPath: path, bytes: 0, outcome: .failed(reason: "could not unload: \(reason)"))
        }
        switch LaunchAgentBootout.run(plist: plist, userID: environment.userID, commands: commands) {
        case .stopped, .notLoaded: return nil
        case .failed(let reason): return failure(reason)
        }
    }
}
