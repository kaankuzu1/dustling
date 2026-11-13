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

/// One app the user uninstalled, with the leftovers they selected (what `uninstall` was given).
public struct UninstallJob: Sendable {
    public let app: InstalledApp
    public let leftovers: [Leftover]

    public init(app: InstalledApp, leftovers: [Leftover]) {
        self.app = app
        self.leftovers = leftovers
    }
}

/// Removes an app and the leftovers the user selected. Everything goes to the Trash through
/// `CleanupRunner`; admin-only leftovers are recorded as "needs admin" and never attempted by
/// `uninstall`. `moveSystemItems` then moves what needs admin with the Mac password, once for a
/// whole uninstall action, when the runner has an `AdminMover`.
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
    /// The declared leftover locations, as `key`s.
    private let locationPaths: Set<String>

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
        locationPaths = Set(LeftoverFinder.locationDirectories(environment).map { Self.key($0) })
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

        let userLeftovers = leftovers.filter { !$0.requiresAdmin }
        let adminLeftovers = leftovers.filter { $0.requiresAdmin }

        let moved = moveUserLeftovers(userLeftovers, onItem: onItem)
        entries += moved.entries
        var extra = moved.unloadFailures
        for leftover in adminLeftovers {
            extra.append(JournalEntry(
                originalPath: leftover.url.path(percentEncoded: false),
                bytes: leftover.bytes, outcome: .needsAdmin))
        }
        return runner.finish(entries + skipEntries + extra, kind: kind, startedAt: startedAt)
    }

    /// Moves what an uninstall action left because it belongs to the system, asking for the Mac
    /// password once for all of `records` (`AdminMover.movePrompt`). `jobs` are what each
    /// `uninstall` was given; a record is matched to its job by the app's path (its first entry).
    /// - An app that needs admin moves with the password, and the admin leftovers kept for it move
    ///   in the same script only if it did. Once it moved, its kept leftovers of the user's own move
    ///   the normal way (launch agents booted out first, as `uninstall` does).
    /// - An app already in the Trash: each leftover that needs admin moves with the password.
    ///
    /// A leftover moves only when `uninstall` would move it: a direct child of a declared location
    /// that the guard allows; otherwise, once its app is in the Trash, it is skipped with that reason
    /// (a package receipt, in a protected location, is one). Outcomes are those of `CleanupRunner.run`:
    /// in the Trash; still needing admin (the password box was closed, or Dustling can't open a folder
    /// the move needs, such as `~/.Trash` without Full Disk Access); skipped if already gone; failed
    /// with the script's reason. Kept leftovers stay kept while their app stays.
    ///
    /// A changed record has its entries replaced in place (unload failures appended), `restorable`
    /// recomputed, and is saved to the journal and logged again; the others come back as they were.
    /// An app that is running again by now is left alone. Without an `AdminMover` (the runner has
    /// none) nothing is asked and the records come back unchanged.
    public func moveSystemItems(_ records: [RunRecord], jobs: [UninstallJob]) async -> [RunRecord] {
        guard runner.admin != nil else { return records }
        return await FileWork.run { _ in moveSystemItemsBlocking(records, jobs: jobs) }
    }

    /// A record's part in the password step.
    private struct SystemPlan {
        let record: Int
        let job: UninstallJob
        /// The app's step, when the app itself moves with the password.
        var app: Int?
        /// Leftover entries with their step.
        var steps: [(entry: Int, step: Int)] = []
        /// Leftover entries settled without the password, applied once the app is in the Trash.
        var settled: [(entry: Int, outcome: DeletionOutcome)] = []
    }

    private func moveSystemItemsBlocking(_ records: [RunRecord], jobs: [UninstallJob]) -> [RunRecord] {
        guard let admin = runner.admin else { return records }
        let roots = self.roots
        let guardPaths = runner.protectedPaths
        let kept = DeletionOutcome.skipped(reason: Self.keptReason)

        /// Why `uninstall` would not move this leftover now, or nil.
        func refusal(_ url: URL) -> DeletionOutcome? {
            guard isLeftoverShaped(url) else { return .skipped(reason: Self.outsideReason) }
            if case .denied(let reason) = guardPaths.verdict(for: url, allowedRoots: roots) {
                return .skipped(reason: reason)
            }
            return Self.isMissing(url) ? .skipped(reason: AdminScript.goneReason) : nil
        }
        func leftover(of job: UninstallJob, _ entry: JournalEntry) -> Leftover? {
            let key = Self.key(URL(filePath: entry.originalPath))
            return job.leftovers.first { Self.key($0.url) == key }
        }

        var moves: [AdminMover.TrashMove] = []
        var plans: [SystemPlan] = []
        var taken = Set<String>()
        for (index, record) in records.enumerated() {
            guard case .uninstall = record.kind, let first = record.entries.first,
                  let job = jobs.first(where: { Self.key($0.app.url) == Self.key(URL(filePath: first.originalPath)) })
            else { continue }
            var plan = SystemPlan(record: index, job: job)
            // The leftover entries this step is for: kept for the app, or left needing admin after it moved.
            let waiting: DeletionOutcome
            switch first.outcome {
            case .needsAdmin:
                guard !running.isRunning(job.app), let move = admin.trashMove(for: job.app.url, taken: &taken)
                else { continue }
                plan.app = moves.count
                moves.append(move)
                waiting = kept
            case .movedToTrash:
                waiting = .needsAdmin
            default:
                continue
            }
            for (entryIndex, entry) in record.entries.enumerated().dropFirst() where entry.outcome == waiting {
                guard let leftover = leftover(of: job, entry), leftover.requiresAdmin else { continue }
                if let outcome = refusal(leftover.url) {
                    plan.settled.append((entryIndex, outcome))
                } else if let move = admin.trashMove(for: leftover.url, taken: &taken, dependsOn: plan.app) {
                    plan.steps.append((entryIndex, moves.count))
                    moves.append(move)
                } else {
                    plan.settled.append((entryIndex, .needsAdmin))
                }
            }
            plans.append(plan)
        }

        let results = admin.performOpenable(moves.map(\.step), prompt: AdminMover.movePrompt)
        var updated = records
        for plan in plans {
            var record = records[plan.record]
            var changed = Set<Int>()
            func settle(_ entryIndex: Int, step: Int) {
                record.entries[entryIndex].outcome = AdminMover.trashOutcome(
                    results[step], destination: moves[step].destination)
                if results[step] == .done { record.entries[entryIndex].trashedIdentity = moves[step].identity }
                changed.insert(entryIndex)
            }
            if let app = plan.app {
                settle(0, step: app)
                guard results[app] == .done else {
                    if record.entries[0] != records[plan.record].entries[0] {
                        updated[plan.record] = runner.update(record, changed: [record.entries[0]])
                    }
                    continue
                }
            }
            for (entryIndex, step) in plan.steps { settle(entryIndex, step: step) }
            for (entryIndex, outcome) in plan.settled {
                record.entries[entryIndex].outcome = outcome
                changed.insert(entryIndex)
            }
            var appended: [JournalEntry] = []
            if plan.app != nil {
                // The app moved: the user's own leftovers kept for it follow, the normal way.
                let follow = record.entries.indices.dropFirst().compactMap { entryIndex -> (Int, Leftover)? in
                    let entry = record.entries[entryIndex]
                    guard entry.outcome == kept, let leftover = leftover(of: plan.job, entry), !leftover.requiresAdmin
                    else { return nil }
                    return (entryIndex, leftover)
                }
                let moved = moveUserLeftovers(follow.map(\.1), onItem: { _, _ in })
                for ((entryIndex, _), entry) in zip(follow, moved.entries) {
                    record.entries[entryIndex] = entry
                    changed.insert(entryIndex)
                }
                appended = moved.unloadFailures
                record.entries += appended
            }
            let changedEntries = changed.sorted().filter { record.entries[$0] != records[plan.record].entries[$0] }
            guard !changedEntries.isEmpty || !appended.isEmpty else { continue }
            updated[plan.record] = runner.update(record, changed: changedEntries.map { record.entries[$0] } + appended)
        }
        return updated
    }

    /// Nothing is at `url` (lstat), as a normal move finds "already gone".
    private static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false)), &info) != 0 else { return false }
        let code = errno
        return code == ENOENT || code == ENOTDIR
    }

    /// The application folders and every declared leftover location: the only roots anything moves from.
    private var roots: [URL] {
        environment.applicationDirectories + LeftoverFinder.locationDirectories(environment)
    }

    /// A leftover is a direct child of a declared location and never a declared location itself
    /// (e.g. steamapps/common or Preferences/ByHost, whose parents are declared locations too).
    private func isLeftoverShaped(_ url: URL) -> Bool {
        locationPaths.contains(Self.key(url.deletingLastPathComponent())) && !locationPaths.contains(Self.key(url))
    }

    /// Moves the leftovers of an app that is now in the Trash, the user's own ones: launch agents in
    /// `~/Library/LaunchAgents` are booted out first, then each leftover moves (or is skipped as
    /// outside the cleanup area). Entries are in the order of `leftovers`; unload failures come apart.
    private func moveUserLeftovers(
        _ leftovers: [Leftover], onItem: (URL, DeletionOutcome) -> Void
    ) -> (entries: [JournalEntry], unloadFailures: [JournalEntry]) {
        var failures: [JournalEntry] = []
        let agentsDirectory = environment.userLibrary.appending(path: "LaunchAgents", directoryHint: .isDirectory)
        let guardPaths = runner.protectedPaths
        for agent in leftovers where agent.kind == .launchAgent {
            // Only agents that really live in ~/Library/LaunchAgents are ever booted out.
            guard guardPaths.verdict(for: agent.url, allowedRoots: [agentsDirectory]) == .allowed,
                  isLeftoverShaped(agent.url)
            else { continue }
            if let failure = unload(agent.url) { failures.append(failure) }
        }
        let roots = self.roots
        var entries: [JournalEntry] = []
        for leftover in leftovers {
            let entry: JournalEntry
            if isLeftoverShaped(leftover.url) {
                entry = runner.attempt(leftover.url, allowedRoots: roots)
            } else {
                entry = JournalEntry(
                    originalPath: leftover.url.path(percentEncoded: false), bytes: leftover.bytes,
                    outcome: .skipped(reason: Self.outsideReason))
            }
            entries.append(entry)
            onItem(leftover.url, entry.outcome)
        }
        return (entries, failures)
    }

    static let outsideReason = "outside the cleanup area"

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
