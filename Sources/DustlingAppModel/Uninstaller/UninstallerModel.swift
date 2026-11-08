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
    /// Leftovers are still being looked for: `leftoverCount` and `totalBytes` are not final yet.
    public let isCounting: Bool
    public let leftoverCount: Int
    /// What removing the app frees: the leftovers, plus the app itself unless it is only a link.
    public let totalBytes: UInt64
    /// "Steam game", "Shortcut", or nil.
    public let label: String?
    /// A warning about the app as a whole (a shortcut only removes the link).
    public let warning: String?
    public var id: URL { app.id }

    public init(
        app: InstalledApp, isCounting: Bool, leftoverCount: Int, totalBytes: UInt64, label: String?, warning: String?
    ) {
        self.app = app
        self.isCounting = isCounting
        self.leftoverCount = leftoverCount
        self.totalBytes = totalBytes
        self.label = label
        self.warning = warning
    }
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

public struct ConfirmModel: Identifiable, Equatable, Sendable {
    public struct PerApp: Equatable, Sendable {
        public let name: String
        /// Items that are not the user's own data (the app itself counts).
        public let items: Int
        /// Checked rows that may hold the user's data; listed separately in `dataWarnings`.
        public let dataItems: Int
        /// Leftovers only the cleanup helper can remove; not moved now and not in `bytes`.
        public let adminItems: Int
        public let bytes: UInt64
    }

    public struct DataWarning: Equatable, Sendable {
        public let appName: String
        public let itemName: String
        public let kind: LeftoverKind
        public let bytes: UInt64
        public let text: String
    }

    /// What will be moved, exactly as the user is shown it. `uninstallSelected` executes this and
    /// nothing else.
    public struct Planned: Equatable, Sendable {
        public let app: InstalledApp
        public let leftovers: [Leftover]
    }

    public let plan: [Planned]
    /// False while a selected app is still being looked at for leftovers (or nothing is selected).
    public let ready: Bool
    /// "Still looking for leftovers" when not ready for that reason.
    public let note: String?
    public let perApp: [PerApp]
    public let dataWarnings: [DataWarning]
    /// Selected apps that are open now; they are asked to quit first.
    public let runningApps: [String]
    /// Checked launch agents; they are unloaded before they move.
    public let launchAgents: Int
    /// Total of the helper-only leftovers across apps, counted apart from what will be freed.
    public let adminItems: Int
    /// "Needs the cleanup helper" when `adminItems > 0`.
    public let adminNote: String?
    public let totalBytes: UInt64
    /// Set while Dustling can't take things back out of the Trash (no Full Disk Access). The sheet
    /// shows it, and `uninstallSelected` refuses a confirmation made without it in that state.
    public let limitedNote: String?
    /// Each confirmation is used at most once (`uninstallSelected` refuses it again).
    public let id = UUID()
    /// The apps that were open when the user confirmed. Only these are asked to quit; one that opened
    /// afterwards is left alone.
    public let runningAppURLs: Set<URL>
    /// Checked leftovers that stay where they are because Full Disk Access is off; not in the totals.
    public let accessSkipped: Int

    init(
        plan: [Planned], ready: Bool, note: String?, perApp: [PerApp], dataWarnings: [DataWarning],
        runningApps: [String], launchAgents: Int, adminItems: Int, adminNote: String?, totalBytes: UInt64,
        limitedNote: String?, runningAppURLs: Set<URL> = [], accessSkipped: Int = 0
    ) {
        self.plan = plan
        self.ready = ready
        self.note = note
        self.perApp = perApp
        self.dataWarnings = dataWarnings
        self.runningApps = runningApps
        self.launchAgents = launchAgents
        self.adminItems = adminItems
        self.adminNote = adminNote
        self.totalBytes = totalBytes
        self.limitedNote = limitedNote
        self.runningAppURLs = runningAppURLs
        self.accessSkipped = accessSkipped
    }
}

/// What the last uninstall did: one record per app that was tried, and the apps Stop left alone.
public struct UninstallResult: Equatable, Sendable {
    public let records: [RunRecord]
    public let stopped: [String]

    public init(records: [RunRecord], stopped: [String]) {
        self.records = records
        self.stopped = stopped
    }
}

public enum UninstallerModelError: Error, Equatable, LocalizedError {
    case cantTakeOutOfTrash, busy, alreadyPutBack

    public var errorDescription: String? {
        switch self {
        case .cantTakeOutOfTrash: "Dustling can't take things out of the Trash without Full Disk Access."
        case .busy: "Dustling is still working on the last request."
        case .alreadyPutBack: "These items were put back already."
        }
    }
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
    /// The Removing state, app by app. Kept after the uninstall for the summary, until `dismissResult()`.
    public private(set) var progress: UninstallProgress?
    /// The last uninstall's records, for the summary.
    public private(set) var result: UninstallResult?
    /// Put back results per run.
    public private(set) var restoreOutcomes: [UUID: [RestoreOutcome]] = [:]
    public private(set) var isRestoring = false
    /// Without Full Disk Access macOS won't let Dustling take anything out of `~/.Trash`: the confirm
    /// sheet warns first and the summary offers Show in Trash instead of Put back.
    public var canTakeOutOfTrash = false
    /// Without Full Disk Access other apps' data (Containers, Group Containers) and the consent folders
    /// can't be opened without a prompt: the list doesn't load, and an uninstall records leftovers
    /// there as skipped ("needs Full Disk Access") and never touches them.
    public var canReadAppData = false
    /// Folders that can't be read now (set with `canReadAppData`); leftovers inside them are skipped.
    @ObservationIgnored public var lockedFolders: [URL] = []
    /// Why the last uninstall request was refused, shown above the list until the next one.
    public private(set) var refusal: String?
    /// Stop was pressed; the app being removed now finishes, the rest are left alone.
    public private(set) var stopRequested = false

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
    private var appList: [InstalledApp] = []
    private var counted: Set<URL> = []
    @ObservationIgnored private var loadPending = false
    @ObservationIgnored private var usedConfirmations: Set<UUID> = []
    #if DEBUG
    /// Set by the screenshot fixture: which fixture apps read as running. Non-nil means fixture mode,
    /// in which nothing is ever moved.
    @ObservationIgnored private var fixtureRunning: Set<URL>?
    #endif

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

    /// Lists the installed apps and publishes them at once (marked counting), then finds each app's
    /// leftovers in the background and publishes each count as it finishes. A newer load makes an
    /// older one stop. Refused while an uninstall is running. Check marks the user made are kept for
    /// leftovers that are found again.
    /// Returns false when the load was refused (no access to app data, an uninstall running, or the
    /// screenshot fixture) and nothing was listed.
    @discardableResult
    public func load() async -> Bool {
        #if DEBUG
        guard fixtureRunning == nil else { return false }
        #endif
        guard !isUninstalling else { loadPending = true; return false }
        guard canReadAppData else { return false }
        generation += 1
        let mine = generation
        isLoading = true
        counted = []
        issues = []
        let scout = self.scout, finder = self.finder, protected = self.protectedPaths
        let discovered = await Blocking.run { scout.discoverWithIssues() }
        guard mine == generation else { return true }
        unreadableAppFolders = discovered.unreadable
        appList = discovered.apps
        let present = Set(discovered.apps.map(\.url))
        rows = rows.filter { present.contains($0.key) }
        selection = selection.filter { url in discovered.apps.contains { $0.url == url } }
        rebuildApps()
        for app in discovered.apps {
            let others = Self.others(than: app, in: discovered.apps)
            let found = await Blocking.run { () -> ([LeftoverRow], [ScanIssue]) in
                let result = finder.leftoversWithIssues(for: app, among: others)
                return (result.leftovers.map { Self.makeRow($0, for: app, protectedPaths: protected) }, result.issues)
            }
            guard mine == generation else { return true }
            let old = Dictionary((rows[app.url] ?? []).map { ($0.id, $0.checked) }, uniquingKeysWith: { _, n in n })
            rows[app.url] = found.0.map { row in
                var merged = row
                if !row.isDisabled, let kept = old[row.id] { merged.checked = kept }
                return merged.withWarning()
            }
            issues += found.1
            counted.insert(app.url)
            rebuildApps()
        }
        isLoading = false
        return true
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

    private func rebuildApps() {
        apps = appList.map { app in
            let leftovers = rows[app.url] ?? []
            let isLink = app.linkTarget != nil
            let leftoverBytes = leftovers.reduce(UInt64(0)) { $0 + $1.leftover.bytes }
            return AppRow(
                app: app, isCounting: !counted.contains(app.url), leftoverCount: leftovers.count,
                totalBytes: leftoverBytes + (isLink ? 0 : app.bytes),
                label: isLink ? "Shortcut" : (app.steamAppID != nil && app.bundleID == nil ? "Steam game" : nil),
                warning: isLink
                    ? "This is a shortcut. Only the link is removed; the app it points to stays where it is." : nil)
        }
    }

    // MARK: leftovers

    nonisolated static let linkReason = "Only the link is removed"

    nonisolated static func makeRow(
        _ leftover: Leftover, for app: InstalledApp, protectedPaths: ProtectedPaths
    ) -> LeftoverRow {
        var badges: [LeftoverBadge] = []
        if leftover.kind == .groupContainer && leftover.match == .exact { badges.append(.teamID) }
        if leftover.requiresAdmin { badges.append(.helper) }
        if leftover.match == .nameBased { badges.append(.nameMatch) }
        if leftover.mayContainUserData { badges.append(.yourData) }
        let disabled = app.linkTarget != nil ? Self.linkReason : protectedPaths.exclusionReason(for: leftover.url)
        let checked = leftover.preselected && disabled == nil
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

    /// What would happen now for the selected apps; `uninstallSelected` takes its own copy of this plan.
    private func plan() -> [(app: InstalledApp, leftovers: [Leftover])] {
        selectedApps.map { ($0.app, checkedLeftovers(for: $0.app)) }
    }

    public var confirmation: ConfirmModel {
        var perApp: [ConfirmModel.PerApp] = []
        var warnings: [ConfirmModel.DataWarning] = []
        var runningNames: [String] = []
        var total: UInt64 = 0
        var adminTotal = 0
        var agents = 0
        var runningURLs: Set<URL> = []
        var accessSkipped = 0
        let planned = plan()
        for (app, checked) in planned {
            // One rule (`block(for:)`) for what moves, here, in Review all files and in the uninstall.
            let admin = checked.filter { block(for: $0) == .needsHelper }
            // Left where they are without Full Disk Access: not counted as moving.
            accessSkipped += checked.filter { block(for: $0) == .needsFullDiskAccess }.count
            let movable = checked.filter { block(for: $0) == nil }
            let data = movable.filter(\.mayContainUserData)
            let bytes = (app.linkTarget == nil ? app.bytes : 0) + movable.reduce(0) { $0 + $1.bytes }
            perApp.append(.init(
                name: app.displayName, items: 1 + movable.count - data.count, dataItems: data.count,
                adminItems: admin.count, bytes: bytes))
            for leftover in data {
                warnings.append(.init(
                    appName: app.displayName, itemName: leftover.url.lastPathComponent, kind: leftover.kind,
                    bytes: leftover.bytes, text: Self.dataWarning(for: leftover)))
            }
            if isRunning(app) {
                runningNames.append(app.displayName)
                runningURLs.insert(app.url)
            }
            total += bytes
            adminTotal += admin.count
            agents += movable.filter { $0.kind == .launchAgent }.count
        }
        let counting = selectedApps.contains { $0.isCounting }
        return ConfirmModel(
            plan: planned.map { .init(app: $0.app, leftovers: $0.leftovers) },
            ready: !counting && !planned.isEmpty, note: counting ? "Still looking for leftovers" : nil,
            perApp: perApp, dataWarnings: warnings, runningApps: runningNames, launchAgents: agents,
            adminItems: adminTotal, adminNote: adminTotal > 0 ? "Needs the cleanup helper" : nil, totalBytes: total,
            limitedNote: canTakeOutOfTrash ? nil : CleanupGate.limitedNote, runningAppURLs: runningURLs,
            accessSkipped: accessSkipped)
    }

    /// Whether the app is open now (the detail header's "Running now.").
    public func isRunning(_ app: InstalledApp) -> Bool {
        #if DEBUG
        if let fixtureRunning { return fixtureRunning.contains(app.url) }
        #endif
        return running.isRunning(app)
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

    /// Uninstalls exactly the apps and leftovers in `confirmed` (the plan the user was shown), one at
    /// a time, and returns one record per app. A running app is asked to quit; if it is not gone
    /// within the timeout it is recorded as skipped (`stillRunningReason`) and the others carry on.
    ///
    /// Refused when the confirmation was already used, or when Dustling can't take things back out of
    /// the Trash and the confirmation didn't say so (access was lost after the sheet opened).
    public func uninstallSelected(confirmed: ConfirmModel, quit: AppQuitter) async -> [RunRecord] {
        #if DEBUG
        // The screenshot fixture's apps are samples with plain display paths (which may name real
        // apps): nothing is ever quit or moved for them, whatever the confirmation says.
        guard fixtureRunning == nil else { return [] }
        #endif
        guard !isUninstalling, !isRestoring, confirmed.ready else { return [] }
        guard !usedConfirmations.contains(confirmed.id) else {
            refusal = Self.usedRefusal
            return []
        }
        guard canTakeOutOfTrash || confirmed.limitedNote != nil else {
            refusal = Self.accessRefusal
            return []
        }
        refusal = nil
        usedConfirmations.insert(confirmed.id)
        isUninstalling = true
        stopRequested = false
        result = nil
        restoreOutcomes = [:]
        // A load in flight is cut off by the generation bump; it is run again once this is done.
        if isLoading { loadPending = true }
        generation += 1
        isLoading = false
        itemsDone = 0
        progress = UninstallProgress(plan: confirmed.plan)
        var records: [RunRecord] = []
        var stopped: [String] = []
        for planned in confirmed.plan {
            let app = planned.app
            if stopRequested {
                stopped.append(app.displayName)
                continue
            }
            let record = await uninstallOne(
                app, leftovers: planned.leftovers, quit: quit, confirmedRunning: confirmed.runningAppURLs.contains(app.url))
            progress?.finish(app.url, record: record)
            records.append(record)
            if record.entries.first.map({ if case .movedToTrash = $0.outcome { true } else { false } }) == true {
                selection.remove(app.url)
                appList.removeAll { $0.url == app.url }
                rows[app.url] = nil
                counted.remove(app.url)
                rebuildApps()
            }
            onRunCompleted()
        }
        if stopRequested { progress?.stopRemaining() }
        result = UninstallResult(records: records, stopped: stopped)
        isUninstalling = false
        if loadPending {
            loadPending = false
            // Not awaited: the records go back now, the recount follows in the background.
            Task { await self.load() }
        }
        return records
    }

    public static let accessRefusal = "Full Disk Access was turned off. Check the list again before moving anything."
    public static let usedRefusal = "That confirmation was already used. Check the list again before moving anything."
    public static let openedAfterConfirmReason = "opened after you confirmed"
    public static let stillRunningReason = "still running after Dustling asked it to quit"
    public static let needsAccessReason = "needs Full Disk Access"

    /// Clears the refusal banner (the user looked at the list again).
    public func clearRefusal() { refusal = nil }

    /// Why a checked leftover won't move now, or nil when it will. The confirmation, Review all files
    /// and the uninstall all ask this.
    public func block(for row: LeftoverRow) -> LeftoverBlock? {
        if let reason = row.disabledReason { return .excluded(reason) }
        return block(for: row.leftover)
    }

    func block(for leftover: Leftover) -> LeftoverBlock? {
        if leftover.requiresAdmin { return .needsHelper }
        if mustSkip(leftover) { return .needsFullDiskAccess }
        return nil
    }

    // MARK: review all files

    /// Every file of the selected apps: the app first, then its leftovers, each with whether it moves
    /// and, when it can't, why.
    public func review() -> UninstallReview {
        UninstallReview(sections: selectedApps.map { row in
            let isLink = row.app.linkTarget != nil
            var rows = [UninstallReview.Row(
                url: row.app.url, title: isLink ? "Shortcut" : "Application", isApp: true,
                bytes: isLink ? 0 : row.app.bytes, badges: [], disabledReason: nil, isIncluded: true,
                dataWarning: nil)]
            for leftover in leftovers(for: row.app) {
                let block = block(for: leftover)
                rows.append(.init(
                    url: leftover.id, title: UninstallerScreen.kindName(leftover.leftover.kind), isApp: false,
                    bytes: leftover.leftover.bytes, badges: leftover.badges, disabledReason: block?.text,
                    isIncluded: block == nil && leftover.checked,
                    dataWarning: leftover.leftover.mayContainUserData ? Self.dataWarning(for: leftover.leftover) : nil))
            }
            return UninstallReview.Section(app: row.app, rows: rows)
        })
    }

    /// The draft Review all files opens with: the leftovers of the selected apps that won't move
    /// because they are unticked.
    public var reviewExclusions: Set<URL> {
        Set(selectedApps.flatMap { app in
            leftovers(for: app.app).filter { !$0.checked && !$0.isDisabled }.map(\.id)
        })
    }

    /// Done in Review all files: an unticked app is deselected; every other row that can be ticked
    /// takes the draft's state. Only `rows` (what the sheet showed) change; rows that can't move, or
    /// that appeared since the sheet opened, stay as they are.
    public func applyReview(excluding: Set<URL>, rows shown: Set<URL>) {
        guard !isUninstalling, !isRestoring else { return }
        for row in selectedApps where shown.contains(row.app.url) {
            if excluding.contains(row.app.url) {
                selection.remove(row.app.url)
                continue
            }
            for leftover in leftovers(for: row.app)
            where shown.contains(leftover.id) && !leftover.isDisabled && block(for: leftover.leftover) == nil {
                let on = !excluding.contains(leftover.id)
                if on != leftover.checked { setChecked(on, leftover: leftover.leftover, in: row.app) }
            }
        }
    }

    /// Leftovers that must not be touched now: other apps' data without Full Disk Access, and anything
    /// in a folder that can't be read.
    func mustSkip(_ leftover: Leftover) -> Bool {
        #if DEBUG
        // The screenshot fixture shows the plan as with access; it never moves anything.
        if fixtureRunning != nil { return false }
        #endif
        if !canReadAppData && (leftover.kind == .container || leftover.kind == .groupContainer) { return true }
        let path = leftover.url.standardizedFileURL.path(percentEncoded: false)
        return lockedFolders.contains { folder in
            var base = folder.standardizedFileURL.path(percentEncoded: false)
            if !base.hasSuffix("/") { base += "/" }
            return path.hasPrefix(base) || path + "/" == base
        }
    }

    /// Stop: the app being removed now finishes (half an app is worse than either), the rest are left alone.
    public func stop() {
        guard isUninstalling else { return }
        stopRequested = true
    }

    /// Back to the list after the summary.
    public func dismissResult() {
        guard !isUninstalling, !isRestoring else { return }
        result = nil
        progress = nil
        restoreOutcomes = [:]
    }

    private func uninstallOne(
        _ app: InstalledApp, leftovers: [Leftover], quit: AppQuitter, confirmedRunning: Bool
    ) async -> RunRecord {
        if running.isRunning(app) {
            // Never quit an app the user didn't see as running when they confirmed.
            guard confirmedRunning else {
                return await recordStillRunning(app, leftovers: leftovers, reason: Self.openedAfterConfirmReason)
            }
            progress?.quitting(app.url)
            _ = await Self.quitWithTimeout(app, quit: quit, timeout: quitTimeout)
            if running.isRunning(app) { return await recordStillRunning(app, leftovers: leftovers) }
        }
        // The one rule: only what it calls "needs Full Disk Access" is held back here; helper-only
        // items go to the core, which records them as needing admin.
        let skipped = leftovers.filter { block(for: $0) == .needsFullDiskAccess }
        let moving = leftovers.filter { block(for: $0) != .needsFullDiskAccess }
        progress?.begin(app.url)
        for leftover in skipped { progress?.record(leftover.url, .skipped(reason: Self.needsAccessReason), in: app.url) }
        let uninstaller = self.uninstaller
        let id = app.url
        let sink = ProgressSink { [weak self] url, outcome in
            Task { @MainActor in
                self?.itemsDone += 1
                self?.progress?.record(url, outcome, in: id)
            }
        }
        do {
            // The uninstaller does its file work on its own GCD queue.
            return try await uninstaller.uninstall(
                app, leftovers: moving, skipped: skipped, skipReason: Self.needsAccessReason
            ) { url, outcome in
                sink.tick(url, outcome)
            }
        } catch {
            // The app opened between the check and the move.
            return await recordStillRunning(app, leftovers: leftovers, error: error)
        }
    }

    private final class ProgressSink: Sendable {
        let tick: @Sendable (URL, DeletionOutcome) -> Void
        init(_ tick: @escaping @Sendable (URL, DeletionOutcome) -> Void) { self.tick = tick }
    }

    // MARK: put back

    /// Puts back what one app's run moved to the Trash (the app and its leftovers), then lists the
    /// apps again. Needs access to the Trash (`canTakeOutOfTrash`); without it the screen offers Show
    /// in Trash instead.
    /// What of the finished uninstall is still in the Trash: everything moved, minus what Put back
    /// brought back since.
    public func bytesStillInTrash(_ records: [RunRecord]) -> UInt64 {
        records.reduce(0) { total, record in
            let restored = Set((restoreOutcomes[record.id] ?? []).compactMap { outcome -> String? in
                if case .restored(let path) = outcome { path } else { nil }
            })
            return total + record.entries.reduce(0) { sum, entry in
                guard case .movedToTrash = entry.outcome, !entry.restored, !restored.contains(entry.originalPath) else { return sum }
                return sum + entry.bytes
            }
        }
    }

    public func putBack(_ record: RunRecord) async throws -> [RestoreOutcome] {
        guard canTakeOutOfTrash else { throw UninstallerModelError.cantTakeOutOfTrash }
        #if DEBUG
        guard fixtureRunning == nil else { throw UninstallerModelError.busy }
        #endif
        guard !isUninstalling, !isRestoring else { throw UninstallerModelError.busy }
        guard restoreOutcomes[record.id] == nil || !(restoreOutcomes[record.id] ?? []).contains(where: {
            if case .restored = $0 { true } else { false }
        }) else { throw UninstallerModelError.alreadyPutBack }
        let paths = Set(record.entries.compactMap { entry -> String? in
            if case .movedToTrash = entry.outcome { entry.originalPath } else { nil }
        })
        guard !paths.isEmpty else { throw RunJournalError.notRestorable(record.id) }
        let journal = self.journal
        let id = record.id
        isRestoring = true
        defer { isRestoring = false }
        do {
            let outcomes = try await Blocking.run { try journal.restore(runID: id, paths: paths) }
            restoreOutcomes[id] = outcomes
            onRunCompleted()
            Task { await self.load() }
            return outcomes
        } catch {
            onRunCompleted()
            throw error
        }
    }

    private func recordStillRunning(
        _ app: InstalledApp, leftovers: [Leftover], error: Error? = nil, reason skipReason: String = UninstallerModel.stillRunningReason
    ) async -> RunRecord {
        let outcome: DeletionOutcome
        if let error, !(error is UninstallError) {
            outcome = .failed(reason: "could not uninstall: \(error.localizedDescription)")
        } else {
            outcome = .skipped(reason: skipReason)
        }
        var entries = [JournalEntry(originalPath: app.url.path(percentEncoded: false), bytes: app.bytes, outcome: outcome)]
        for leftover in leftovers {
            entries.append(JournalEntry(
                originalPath: leftover.url.path(percentEncoded: false), bytes: leftover.bytes,
                outcome: .skipped(reason: "kept because the app itself was not removed")))
        }
        let record = RunRecord(
            startedAt: Date(), kind: .uninstall(appName: app.displayName), entries: entries, restorable: false)
        // Journal and log writes block: off the main actor.
        let journal = self.journal
        let logger = self.logger
        return await Blocking.run { () -> RunRecord in
            var record = record
            do { try journal.save(record) } catch {
                record.entries.append(JournalEntry(originalPath: "<history>", bytes: 0, outcome: .failed(reason: error.localizedDescription)))
            }
            do { try logger.write(record) } catch {
                record.entries.append(JournalEntry(originalPath: "<log>", bytes: 0, outcome: .failed(reason: error.localizedDescription)))
                try? journal.save(record)
            }
            return record
        }
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

#if DEBUG
extension UninstallerModel {
    /// Screenshot fixture (DEBUG only): shows these apps and leftovers without reading the disk. The
    /// model then refuses to load, uninstall or put back anything.
    public func showFixture(
        apps: [InstalledApp], leftovers: [URL: [Leftover]], running: Set<URL>, selection: Set<URL>,
        checked: [URL] = [], excluded: [URL: String] = [:]
    ) {
        generation += 1
        fixtureRunning = running
        isLoading = false
        appList = apps
        rows = [:]
        for app in apps {
            rows[app.url] = (leftovers[app.url] ?? []).map { leftover in
                var row = Self.makeRow(leftover, for: app, protectedPaths: protectedPaths)
                if let reason = excluded[leftover.url] {
                    row = LeftoverRow(leftover: leftover, checked: false, badges: row.badges, warning: nil,
                                      disabledReason: reason)
                }
                if checked.contains(leftover.url), !row.isDisabled { row.checked = true }
                return row.withWarning()
            }
        }
        counted = Set(apps.map(\.url))
        self.selection = selection
        rebuildApps()
    }

    /// Screenshot fixture (DEBUG only): a load that is still running. With no `apps` nothing is listed
    /// yet; with `apps` they are listed and none is counted yet. Nothing is read from the disk.
    public func showFixtureLoading(apps: [InstalledApp] = []) {
        generation += 1
        fixtureRunning = []
        isLoading = true
        appList = apps
        rows = [:]
        counted = []
        selection = []
        rebuildApps()
    }

    /// Screenshot fixture: the Removing state (`removing`) or the summary (`result`).
    public func showFixtureRun(progress: UninstallProgress?, result: UninstallResult?, uninstalling: Bool) {
        self.progress = progress
        self.result = result
        isUninstalling = uninstalling
    }

    /// Screenshot fixture: a progress that has reached this point.
    public static func fixtureProgress(
        plan: [ConfirmModel.Planned], records: [URL: RunRecord], current: URL?, doneInCurrent: Int
    ) -> UninstallProgress {
        var progress = UninstallProgress(plan: plan)
        for planned in plan {
            if let record = records[planned.app.url] {
                progress.begin(planned.app.url)
                progress.finish(planned.app.url, record: record)
            } else if planned.app.url == current {
                progress.begin(planned.app.url)
                let items = progress.apps.first { $0.id == planned.app.url }?.items ?? []
                for item in items.prefix(doneInCurrent) {
                    progress.record(item.url, .movedToTrash(trashedPath: "/fixture"), in: planned.app.url)
                }
            }
        }
        return progress
    }
}
#endif

private extension LeftoverRow {
    /// A checked row that may hold the user's data carries the warning text.
    func withWarning() -> LeftoverRow {
        LeftoverRow(
            leftover: leftover, checked: checked, badges: badges,
            warning: checked && leftover.mayContainUserData ? UninstallerModel.dataWarning(for: leftover) : nil,
            disabledReason: disabledReason)
    }
}
