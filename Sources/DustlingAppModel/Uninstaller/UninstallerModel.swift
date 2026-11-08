import DustlingCore
import Foundation
import Observation

/// Quits a running app before it is uninstalled. The real implementation lives in the app target.
/// An implementation must honour task cancellation; the model also stops waiting after its own timeout.
public protocol AppQuitter: Sendable {
    /// True when the app was asked to quit and did. False when it refused or could not be quit.
    func quit(_ app: InstalledApp) async -> Bool
}

public enum LeftoverBadge: Equatable, Sendable {
    /// A Group Container matched exactly by the app's Team ID.
    case teamID
    /// Needs the cleanup helper (admin rights) to be removed.
    case helper
    /// Matched by name only, so it might belong to something else.
    case nameMatch
    /// May hold the user's own documents or settings.
    case yourData
}

public struct AppRow: Identifiable, Equatable, Sendable {
    public let app: InstalledApp
    public let leftoverCount: Int
    /// What removing the app frees: the leftovers, plus the app itself unless it is only a link.
    public let totalBytes: UInt64
    /// "Steam game", "Shortcut", or nil.
    public let label: String?
    /// A warning about the app as a whole (a shortcut only removes the link).
    public let warning: String?
    public var id: URL { app.id }
}

public struct LeftoverRow: Identifiable, Equatable, Sendable {
    public let leftover: Leftover
    public var checked: Bool
    public let badges: [LeftoverBadge]
    /// Set while a `yourData` row is checked.
    public let warning: String?
    /// Unchecked and unavailable, with the reason (e.g. "excluded in Settings").
    public let disabledReason: String?
    public var isDisabled: Bool { disabledReason != nil }
    public var id: URL { leftover.id }
}

public struct ConfirmModel: Equatable, Sendable {
    public struct PerApp: Equatable, Sendable {
        public let name: String
        /// Items that are not the user's own data (the app itself counts).
        public let items: Int
        /// Checked rows that may hold the user's data; listed separately in `dataWarnings`.
        public let dataItems: Int
        public let bytes: UInt64
    }

    public struct DataWarning: Equatable, Sendable {
        public let appName: String
        public let itemName: String
        public let text: String
    }

    public let perApp: [PerApp]
    public let dataWarnings: [DataWarning]
    /// Selected apps that are open now; they are asked to quit first.
    public let runningApps: [String]
    public let totalBytes: UInt64
}

/// Drives the Uninstaller screen: the app list with leftover counts, per-app leftover checklists,
/// a confirmation, and an uninstall that goes app by app.
@MainActor @Observable
public final class UninstallerModel {
    public private(set) var apps: [AppRow] = []
    /// Apps ticked for uninstall.
    public var selection: Set<URL> = []
    public private(set) var isLoading = false
    public private(set) var isUninstalling = false
    /// Folders that could not be read while listing apps or finding leftovers.
    public private(set) var issues: [ScanIssue] = []
    public private(set) var unreadableAppFolders: [URL] = []
    /// Items finished so far in the current uninstall.
    public private(set) var itemsDone = 0

    @ObservationIgnored private let scout: AppScout
    @ObservationIgnored private let finder: LeftoverFinder
    @ObservationIgnored private let uninstaller: Uninstaller
    @ObservationIgnored private let running: RunningAppsProviding
    @ObservationIgnored private let protectedPaths: ProtectedPaths
    @ObservationIgnored private let journal: RunJournal
    @ObservationIgnored private let logger: RunLogger
    @ObservationIgnored private let quitTimeout: Duration
    @ObservationIgnored private let onRunCompleted: @MainActor () -> Void
    @ObservationIgnored private var generation = 0
    private var rows: [URL: [LeftoverRow]] = [:]

    public init(
        scout: AppScout, finder: LeftoverFinder, uninstaller: Uninstaller, running: RunningAppsProviding,
        protectedPaths: ProtectedPaths, journal: RunJournal, logger: RunLogger,
        quitTimeout: Duration = .seconds(10),
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.scout = scout
        self.finder = finder
        self.uninstaller = uninstaller
        self.running = running
        self.protectedPaths = protectedPaths
        self.journal = journal
        self.logger = logger
        self.quitTimeout = quitTimeout
        self.onRunCompleted = onRunCompleted
    }

    // MARK: loading

    /// Lists the installed apps and finds each one's leftovers, off the main actor. A newer load
    /// wins over an older one.
    public func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        let scout = self.scout, finder = self.finder, protected = self.protectedPaths
        let found = await Task.detached(priority: .userInitiated) { () -> Loaded in
            let discovered = scout.discoverWithIssues()
            var issues: [ScanIssue] = []
            var perApp: [(InstalledApp, [Leftover])] = []
            for app in discovered.apps {
                let others = Self.others(than: app, in: discovered.apps)
                let result = finder.leftoversWithIssues(for: app, among: others)
                issues += result.issues
                perApp.append((app, result.leftovers))
            }
            let built = perApp.map { app, leftovers in
                (app, leftovers.map { Self.makeRow($0, for: app, protectedPaths: protected) })
            }
            return Loaded(apps: discovered.apps, unreadable: discovered.unreadable, issues: issues, rows: built)
        }.value
        guard mine == generation else { return }
        isLoading = false
        issues = found.issues
        unreadableAppFolders = found.unreadable
        rows = Dictionary(found.rows.map { ($0.0.url, $0.1) }, uniquingKeysWith: { _, new in new })
        selection = selection.filter { url in found.apps.contains { $0.url == url } }
        rebuildApps(found.apps)
    }

    private struct Loaded: Sendable {
        let apps: [InstalledApp]
        let unreadable: [URL]
        let issues: [ScanIssue]
        let rows: [(InstalledApp, [LeftoverRow])]
    }

    /// Every app except the target and the apps nested inside its bundle.
    nonisolated static func others(than app: InstalledApp, in all: [InstalledApp]) -> [InstalledApp] {
        let target = app.url.standardizedFileURL.pathComponents
        return all.filter { other in
            if other.url == app.url { return false }
            let parts = other.url.standardizedFileURL.pathComponents
            return !(parts.count > target.count && Array(parts.prefix(target.count)) == target)
        }
    }

    private func rebuildApps(_ list: [InstalledApp]) {
        apps = list.map { app in
            let leftovers = rows[app.url] ?? []
            let isLink = app.linkTarget != nil
            let leftoverBytes = leftovers.reduce(UInt64(0)) { $0 + $1.leftover.bytes }
            return AppRow(
                app: app, leftoverCount: leftovers.count,
                totalBytes: leftoverBytes + (isLink ? 0 : app.bytes),
                label: isLink ? "Shortcut" : (app.steamAppID != nil && app.bundleID == nil ? "Steam game" : nil),
                warning: isLink
                    ? "This is a shortcut. Only the link is removed; the app it points to stays where it is." : nil)
        }
    }

    // MARK: leftovers

    nonisolated static func makeRow(
        _ leftover: Leftover, for app: InstalledApp, protectedPaths: ProtectedPaths
    ) -> LeftoverRow {
        var badges: [LeftoverBadge] = []
        if leftover.kind == .groupContainer && leftover.match == .exact { badges.append(.teamID) }
        if leftover.requiresAdmin { badges.append(.helper) }
        if leftover.match == .nameBased { badges.append(.nameMatch) }
        if leftover.mayContainUserData { badges.append(.yourData) }
        let disabled = protectedPaths.exclusionReason(for: leftover.url)
        let checked = leftover.preselected && app.linkTarget == nil && disabled == nil
        return LeftoverRow(
            leftover: leftover, checked: checked, badges: badges, warning: nil, disabledReason: disabled)
            .withWarning()
    }

    public func leftovers(for app: InstalledApp) -> [LeftoverRow] { rows[app.url] ?? [] }

    /// Ticks or unticks one leftover. A disabled row stays unchecked.
    public func setChecked(_ checked: Bool, leftover: Leftover, in app: InstalledApp) {
        guard var list = rows[app.url], let index = list.firstIndex(where: { $0.id == leftover.id }),
              !list[index].isDisabled
        else { return }
        list[index].checked = checked
        rows[app.url] = list.map { $0.withWarning() }
    }

    // MARK: confirmation

    public var selectedApps: [AppRow] { apps.filter { selection.contains($0.app.url) } }

    private func checkedLeftovers(for app: InstalledApp) -> [Leftover] {
        // A shortcut never removes anything but the link.
        guard app.linkTarget == nil else { return [] }
        return leftovers(for: app).filter { $0.checked && !$0.isDisabled }.map(\.leftover)
    }

    public var confirmation: ConfirmModel {
        var perApp: [ConfirmModel.PerApp] = []
        var warnings: [ConfirmModel.DataWarning] = []
        var runningNames: [String] = []
        var total: UInt64 = 0
        for row in selectedApps {
            let checked = checkedLeftovers(for: row.app)
            let data = checked.filter(\.mayContainUserData)
            let bytes = (row.app.linkTarget == nil ? row.app.bytes : 0) + checked.reduce(0) { $0 + $1.bytes }
            perApp.append(.init(
                name: row.app.displayName, items: 1 + checked.count - data.count, dataItems: data.count, bytes: bytes))
            for leftover in data {
                warnings.append(.init(
                    appName: row.app.displayName, itemName: leftover.url.lastPathComponent,
                    text: Self.dataWarning(for: leftover)))
            }
            if running.isRunning(row.app) { runningNames.append(row.app.displayName) }
            total += bytes
        }
        return ConfirmModel(perApp: perApp, dataWarnings: warnings, runningApps: runningNames, totalBytes: total)
    }

    nonisolated static func dataWarning(for leftover: Leftover) -> String {
        let what: String
        if let note = leftover.note, !note.isEmpty {
            what = note.hasSuffix(".") ? String(note.dropLast()) : note
        } else {
            switch leftover.kind {
            case .applicationSupport: what = "It can hold the app's documents, saves and settings"
            case .container, .groupContainer: what = "It holds the app's sandboxed documents and settings"
            case .steamGameData: what = "It can hold game saves"
            default: what = "It can hold your own files or settings"
            }
        }
        return "This is your data. \(what). You can put it back from the Trash, but not after you empty it."
    }

    // MARK: uninstall

    /// Uninstalls the selected apps one at a time and returns one record per app. A running app is
    /// asked to quit; if it is not gone within the timeout it is recorded as skipped ("still
    /// running") and the others carry on.
    public func uninstallSelected(quit: AppQuitter) async -> [RunRecord] {
        guard !isUninstalling else { return [] }
        isUninstalling = true
        itemsDone = 0
        defer { isUninstalling = false }
        var records: [RunRecord] = []
        for row in selectedApps {
            let app = row.app
            let chosen = checkedLeftovers(for: app)
            let record = await uninstallOne(app, leftovers: chosen, quit: quit)
            records.append(record)
            if record.entries.first.map({ if case .movedToTrash = $0.outcome { true } else { false } }) == true {
                selection.remove(app.url)
                apps.removeAll { $0.app.url == app.url }
                rows[app.url] = nil
            }
            onRunCompleted()
        }
        return records
    }

    private func uninstallOne(_ app: InstalledApp, leftovers: [Leftover], quit: AppQuitter) async -> RunRecord {
        if running.isRunning(app) {
            _ = await Self.quitWithTimeout(app, quit: quit, timeout: quitTimeout)
            if running.isRunning(app) { return recordStillRunning(app, leftovers: leftovers) }
        }
        let uninstaller = self.uninstaller
        let counter = ProgressSink { [weak self] in
            Task { @MainActor in self?.itemsDone += 1 }
        }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try await uninstaller.uninstall(app, leftovers: leftovers) { _, _ in counter.tick() }
            }.value
        } catch {
            // The app opened between the check and the move.
            return recordStillRunning(app, leftovers: leftovers, error: error)
        }
    }

    private final class ProgressSink: Sendable {
        let tick: @Sendable () -> Void
        init(_ tick: @escaping @Sendable () -> Void) { self.tick = tick }
    }

    private func recordStillRunning(_ app: InstalledApp, leftovers: [Leftover], error: Error? = nil) -> RunRecord {
        let reason: String
        if let error, !(error is UninstallError) { reason = "could not uninstall: \(error.localizedDescription)" }
        else { reason = "still running" }
        let outcome: DeletionOutcome = reason == "still running" ? .skipped(reason: reason) : .failed(reason: reason)
        var entries = [JournalEntry(originalPath: app.url.path(percentEncoded: false), bytes: app.bytes, outcome: outcome)]
        for leftover in leftovers {
            entries.append(JournalEntry(
                originalPath: leftover.url.path(percentEncoded: false), bytes: leftover.bytes,
                outcome: .skipped(reason: "kept because the app itself was not removed")))
        }
        var record = RunRecord(
            startedAt: Date(), kind: .uninstall(appName: app.displayName), entries: entries, restorable: false)
        do { try journal.save(record) } catch {
            record.entries.append(JournalEntry(originalPath: "<history>", bytes: 0, outcome: .failed(reason: error.localizedDescription)))
        }
        do { try logger.write(record) } catch {
            record.entries.append(JournalEntry(originalPath: "<log>", bytes: 0, outcome: .failed(reason: error.localizedDescription)))
            try? journal.save(record)
        }
        return record
    }

    /// Waits for `quit` but never longer than `timeout`, even if the quitter ignores cancellation.
    nonisolated static func quitWithTimeout(_ app: InstalledApp, quit: AppQuitter, timeout: Duration) async -> Bool {
        let gate = OnceGate()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            gate.finish(false)
        }
        let work = Task { gate.finish(await quit.quit(app)) }
        let answered = await withCheckedContinuation { gate.install($0) }
        timer.cancel()
        work.cancel()
        return answered
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func install(_ c: CheckedContinuation<Bool, Never>) {
            lock.lock()
            if let result { lock.unlock(); c.resume(returning: result) } else { continuation = c; lock.unlock() }
        }

        func finish(_ value: Bool) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}

private extension LeftoverRow {
    /// A checked row that may hold the user's data carries the warning text.
    func withWarning() -> LeftoverRow {
        LeftoverRow(
            leftover: leftover, checked: checked, badges: badges,
            warning: checked && leftover.mayContainUserData ? UninstallerModel.dataWarning(for: leftover) : nil,
            disabledReason: disabledReason)
    }
}
