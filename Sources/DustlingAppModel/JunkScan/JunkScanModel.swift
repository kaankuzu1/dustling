import DustlingCore
import Foundation
import Observation

/// One category as the Junk screen shows it. Numbers come from the scan's returned `CategoryScan`s,
/// never from live progress.
public struct CategoryTileModel: Identifiable, Equatable, Sendable {
    public let id: JunkCategoryID
    public let title: String
    /// A line under the title, e.g. for data that is never selected for the user.
    public let note: String?
    /// The category's size. When `stopped`, only what had been measured: show it as "at least".
    public let bytes: UInt64
    public let itemCount: Int
    public let selection: Selection
    public var isSelected: Bool
    /// The scan was stopped in or before this category: its numbers are partial or absent, and it
    /// can't be selected or cleaned.
    public let stopped: Bool
    public let issues: [ScanIssue]
    /// Items belonging to apps that are open right now; a clean leaves them alone.
    public let inUseCount: Int
    /// macOS manages what is in it (System caches and logs, `JunkCategory.isNeverCleaned`): shown with
    /// its size for information, never selected, not even by choice, and never cleaned.
    public var leftAlone: Bool = false
    /// Files the user left out in Review files: never moved, never counted as selected.
    public var excludedCount: Int = 0
    public var excludedBytes: UInt64 = 0
}

/// How far a cleanup has got through one category's items (the moves it attempts).
public struct CategoryProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var isFinished: Bool { done >= total }
}

/// What a finished cleanup did in one category, from the run's recorded outcomes only.
public struct CategoryOutcome: Equatable, Sendable {
    public var movedBytes: UInt64
    public var movedCount: Int
    public var skippedCount: Int
    public var failedCount: Int
    public var needsAdminCount: Int
    /// Moved items that Put everything back returned to where they were.
    public var restoredCount: Int

    public init(
        movedBytes: UInt64 = 0, movedCount: Int = 0, skippedCount: Int = 0, failedCount: Int = 0,
        needsAdminCount: Int = 0, restoredCount: Int = 0
    ) {
        self.movedBytes = movedBytes
        self.movedCount = movedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.needsAdminCount = needsAdminCount
        self.restoredCount = restoredCount
    }

    /// Splits a run's entries by the category each original path came from. Entries of no category
    /// (`<history>`, `<log>`) are left out here; the run summary still lists them.
    public static func split(
        _ record: RunRecord, categoryOf: [String: JunkCategoryID]
    ) -> [JunkCategoryID: CategoryOutcome] {
        var result: [JunkCategoryID: CategoryOutcome] = [:]
        for entry in record.entries {
            guard let id = categoryOf[entry.originalPath] else { continue }
            var outcome = result[id] ?? CategoryOutcome()
            switch entry.outcome {
            case .movedToTrash:
                outcome.movedBytes += entry.bytes
                outcome.movedCount += 1
            case .skipped: outcome.skippedCount += 1
            case .failed: outcome.failedCount += 1
            case .needsAdmin: outcome.needsAdminCount += 1
            case .deleted: break
            }
            result[id] = outcome
        }
        return result
    }
}

/// What a finished cleanup did, read only from the run's recorded outcomes.
public struct CleanSummary: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let path: String
        public let reason: String
    }

    public let movedBytes: UInt64
    public let movedCount: Int
    public let skipped: [Line]
    public let failed: [Line]
    public let needsAdminCount: Int

    public init(_ record: RunRecord) {
        var moved = 0
        var skipped: [Line] = []
        var failed: [Line] = []
        for entry in record.entries {
            switch entry.outcome {
            case .movedToTrash: moved += 1
            case .skipped(let reason): skipped.append(Line(path: entry.originalPath, reason: reason))
            case .failed(let reason): failed.append(Line(path: entry.originalPath, reason: reason))
            case .needsAdmin, .deleted: break
            }
        }
        movedBytes = record.bytesMovedToTrash
        movedCount = moved
        self.skipped = skipped
        self.failed = failed
        needsAdminCount = record.needsAdminCount
    }
}

/// What a cleanup does while Dustling can't take items back out of the Trash (no Full Disk Access):
/// macOS then refuses to let it read `~/.Trash`, so Put everything back can't work.
public enum LimitedCleanupPolicy: Equatable, Sendable {
    /// Clean after a confirmation that says so; the summary offers Show in Trash instead of Put back.
    case warnBeforeCleaning
    /// Don't clean at all until access is on.
    case refuseToClean
}

/// Whether a cleanup may run now, what to tell the user first, and how the summary offers to undo it.
public struct CleanupGate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case allowed, confirmFirst, refused }
    public enum Undo: Equatable, Sendable {
        /// Dustling moves the items back itself.
        case putEverythingBack
        /// Opens the Trash in Finder, where the user can drag the items back.
        case showInTrash
    }

    public static let limitedNote = "Without Full Disk Access, Dustling can't put these back for you. "
        + "You can still drag them out of the Trash in Finder."
    public static let refusedNote = "Dustling moves files to the Trash only with Full Disk Access, "
        + "so it can always put them back."

    public let kind: Kind
    /// Shown before cleaning (confirmFirst) or instead of cleaning (refused).
    public let note: String?
    public let undo: Undo

    public static func make(canTakeOutOfTrash: Bool, policy: LimitedCleanupPolicy) -> CleanupGate {
        if canTakeOutOfTrash { return CleanupGate(kind: .allowed, note: nil, undo: .putEverythingBack) }
        switch policy {
        case .warnBeforeCleaning: return CleanupGate(kind: .confirmFirst, note: limitedNote, undo: .showInTrash)
        case .refuseToClean: return CleanupGate(kind: .refused, note: refusedNote, undo: .showInTrash)
        }
    }
}

/// Places a cleanup must leave alone because they can't be read now (access was revoked after the
/// scan). Their items are recorded as skipped and never touched.
public struct CleanupSkip: Equatable, Sendable {
    /// Categories whose place doesn't read as open now.
    public var categories: Set<JunkCategoryID>
    /// Folders whose contents are off limits now (e.g. other apps' containers without Full Disk Access).
    public var folders: [URL]

    public static let none = CleanupSkip(categories: [], folders: [])
    public static let reason = "needs Full Disk Access"

    /// From the places check now: places that don't read as open are skipped whole; for places that
    /// are only partly open, the folders holding their expanded roots (other apps' containers).
    public static func from(places: [Place], catalog: [JunkCategory]) -> CleanupSkip {
        let closed = Set(places.filter { $0.access != .readable }.map(\.id))
        let partly = Set(places.filter { $0.access == .readable && $0.lockedExpansions }.map(\.id))
        let folders = catalog
            .filter { partly.contains($0.id) }
            .flatMap { $0.expansions.map(\.parent) }
        return CleanupSkip(categories: closed, folders: folders)
    }

    public init(categories: Set<JunkCategoryID>, folders: [URL]) {
        self.categories = categories
        self.folders = folders
    }

    func skips(_ item: JunkItem) -> Bool { skips(item.url, category: item.category) }

    /// Whether an item of `category` at `url` must be left alone now. Text only: never reads the disk.
    public func skips(_ url: URL, category: JunkCategoryID) -> Bool {
        if categories.contains(category) { return true }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return folders.contains { folder in
            var base = folder.standardizedFileURL.path(percentEncoded: false)
            if !base.hasSuffix("/") { base += "/" }
            return path.hasPrefix(base)
        }
    }
}

public enum JunkScanModelError: Error, Equatable, LocalizedError, Sendable {
    case noCleanupToUndo
    case alreadyPutBack
    case alreadyPuttingBack

    public var errorDescription: String? {
        switch self {
        case .noCleanupToUndo: "There is no cleanup to put back."
        case .alreadyPutBack: "This cleanup was already put back."
        case .alreadyPuttingBack: "This cleanup is already being put back."
        }
    }
}

/// Drives the Junk screen: scan with live progress and Stop, category tiles, clean with per-item
/// progress, an honest summary, and Put everything back.
///
/// The engine's callbacks run on its own threads; every one hops to the main actor before touching
/// state, and carries the scan's generation so a late callback can't overwrite a newer state.
@MainActor @Observable
public final class JunkScanModel {
    public enum State: Sendable {
        case idle
        case scanning(ScanProgress)
        case ready
        case moving(done: Int, total: Int, bytes: UInt64)
        case done(RunRecord)
    }

    public private(set) var state: State = .idle
    public private(set) var categories: [CategoryTileModel] = []
    /// What the last Put everything back did, item by item.
    public private(set) var restoreOutcomes: [RestoreOutcome]?
    /// A plain sentence about the last action that did nothing (e.g. nothing selected); nil otherwise.
    public private(set) var message: String?
    /// True once the run just made was put back (allowed once per run).
    public private(set) var didPutBack = false
    /// Places that can't be read now (from the places check). Selected totals, Review files and
    /// `clean()` leave their items out.
    public var cleanupSkip: CleanupSkip = .none
    /// Files left out in Review files. They stay where they are and get no journal entry; a rescan
    /// clears them.
    public private(set) var excludedItems: Set<URL> = []
    /// True while Put everything back runs; a second one is refused meanwhile.
    public private(set) var isRestoring = false
    /// Per category, how far the cleanup in progress (or the last one) got.
    public private(set) var categoryProgress: [JunkCategoryID: CategoryProgress] = [:]
    /// Per category, what the last cleanup did (from its recorded outcomes). Empty until one finishes.
    public private(set) var categoryOutcomes: [JunkCategoryID: CategoryOutcome] = [:]
    /// The category of each path in the run `categoryOutcomes` describes, for Put everything back.
    private var outcomeCategoryOf: [String: JunkCategoryID] = [:]
    /// When the last scan finished (completed or stopped); nil before the first.
    public private(set) var lastScanFinishedAt: Date?
    /// False while Dustling can't take items back out of the Trash (Full Disk Access is off).
    /// Unknown until the app reports it, so it starts false.
    public var canTakeOutOfTrash = false
    /// What happens to a cleanup while `canTakeOutOfTrash` is false.
    public var limitedCleanupPolicy: LimitedCleanupPolicy = .warnBeforeCleaning
    /// Reads the bundle IDs running right now; `clean()` re-checks in-use with it before every cleanup.
    /// nil: keep what the scan saw.
    @ObservationIgnored public var runningBundleIDs: (@Sendable () -> Set<String>)?
    /// What moves items of the system with the Mac password now, read when a cleanup or Put
    /// everything back starts: one password box for all of them. The app passes one only while
    /// Dustling has Full Disk Access (and never in its QA copy); nil: they stay needing admin.
    @ObservationIgnored public var admin: @MainActor () -> AdminMover? = { nil }
    /// Owner bundle ID → running, from the last re-check. Empty until one (the scan's view holds).
    private var runningNow: [String: Bool] = [:]
    /// Apps closed before the last cleanup, by name, for the summary. A rescan clears them.
    public private(set) var closedApps: [String] = []
    /// True while the Review files sheet is open; the app holds off automatic rescans meanwhile, so
    /// the sheet and its draft stay put.
    public var isReviewingFiles = false
    /// Applied at the next scan (the "Preselect safe categories" setting).
    public var preselectSafe: Bool
    #if DEBUG
    /// The DEBUG screenshot fixture is showing: nothing is scanned, cleaned or put back.
    @ObservationIgnored public private(set) var isFixture = false
    #endif

    @ObservationIgnored private let scanner: JunkScanner
    @ObservationIgnored private let runner: CleanupRunner
    @ObservationIgnored private let journal: RunJournal
    @ObservationIgnored private let environment: SystemEnvironment
    @ObservationIgnored private let makeCategories: @Sendable () -> [JunkCategory]
    @ObservationIgnored private let onRunCompleted: @MainActor () -> Void
    @ObservationIgnored private var scans: [JunkCategoryID: CategoryScan] = [:]
    @ObservationIgnored private var order: [JunkCategoryID] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cleanTask: Task<RunRecord, Never>?
    @ObservationIgnored private var generation = 0

    /// `categories` defaults to the standard catalog for `environment` and `options`.
    /// `onRunCompleted` fires after every cleanup and every restore (e.g. `HealthModel.refreshLastRun`).
    public init(
        scanner: JunkScanner, runner: CleanupRunner, journal: RunJournal, environment: SystemEnvironment,
        options: ScanOptions = ScanOptions(), preselectSafe: Bool = true,
        categories: (@Sendable () -> [JunkCategory])? = nil,
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.scanner = scanner
        self.runner = runner
        self.journal = journal
        self.environment = environment
        self.preselectSafe = preselectSafe
        self.makeCategories = categories ?? { JunkCatalog.standard(environment, options: options) }
        self.onRunCompleted = onRunCompleted
    }

    // MARK: derived

    /// What a clean would move: selected, fully scanned categories, minus the items of apps that are
    /// open right now.
    public var selectedBytes: UInt64 {
        selectedBytesByCategory.values.reduce(0, +)
    }

    /// True when a clean would have something to move or record: a selected, fully scanned category
    /// with an item that wasn't left out in Review files (the same test `clean` makes).
    public var hasItemsToMove: Bool {
        categories.contains { tile in
            guard tile.isSelected, !tile.stopped, let scan = scans[tile.id] else { return false }
            return scan.items.contains { !excludedItems.contains($0.url) }
        }
    }

    /// `selectedBytes` per selected category, so a caller can leave out places it can't read now.
    public var selectedBytesByCategory: [JunkCategoryID: UInt64] {
        var result: [JunkCategoryID: UInt64] = [:]
        for tile in categories {
            guard tile.isSelected, !tile.stopped, let scan = scans[tile.id] else { continue }
            result[tile.id] = scan.items
                .filter {
                    !excludedItems.contains($0.url)
                        && Unmovable.check($0, category: scan.category, skipping: cleanupSkip, inUseBy: inUseOwner($0)) == nil
                }
                .reduce(0) { $0 + $1.bytes }
        }
        return result
    }

    public var summary: CleanSummary? {
        if case .done(let record) = state { CleanSummary(record) } else { nil }
    }

    /// True while the run just made can still be put back (once per run).
    public var canPutBack: Bool {
        if case .done(let record) = state { !didPutBack && record.restorable } else { false }
    }

    public var cleanupGate: CleanupGate {
        CleanupGate.make(canTakeOutOfTrash: canTakeOutOfTrash, policy: limitedCleanupPolicy)
    }

    public var isBusy: Bool {
        if isRestoring { return true }
        switch state {
        case .scanning, .moving: return true
        default: return false
        }
    }

    // MARK: scan

    public func scan() {
        #if DEBUG
        guard !isFixture else { return }
        #endif
        guard !isBusy else { return }
        generation += 1
        let mine = generation
        let catalog = makeCategories()
        order = catalog.filter { $0.selection != .emptyTrashOnly }.map(\.id)
        scans = [:]
        categories = []
        restoreOutcomes = nil
        message = nil
        didPutBack = false
        excludedItems = []
        closedApps = []
        runningNow = [:]
        categoryProgress = [:]
        categoryOutcomes = [:]
        state = .scanning(ScanProgress(
            currentPath: environment.home, bytesFound: 0, categoriesDone: 0, categoriesTotal: catalog.count))
        let scanner = self.scanner
        scanTask = Task { [self] in
            let results = await scanner.scan(
                catalog,
                onCategory: { finished in
                    Task { @MainActor in self.categoryFinished(finished, generation: mine) }
                },
                onProgress: { progress in
                    Task { @MainActor in self.progressed(progress, generation: mine) }
                })
            self.scanFinished(results, catalog: catalog, generation: mine)
        }
    }

    /// Stops a scan or a cleanup. A stopped scan keeps what it found and marks the category in
    /// progress (and any not yet reached) as stopped; a stopped cleanup records the rest as skipped.
    public func stop() {
        scanTask?.cancel()
        cleanTask?.cancel()
    }

    /// Suspends until the scan in flight (if any) has finished and published its results.
    public func awaitScan() async {
        await scanTask?.value
    }

    private func progressed(_ progress: ScanProgress, generation: Int) {
        guard generation == self.generation, case .scanning = state else { return }
        state = .scanning(progress)
    }

    private func categoryFinished(_ scan: CategoryScan, generation: Int) {
        guard generation == self.generation, case .scanning = state else { return }
        scans[scan.category.id] = scan
        rebuildTiles()
    }

    private func scanFinished(_ results: [CategoryScan], catalog: [JunkCategory], generation: Int) {
        guard generation == self.generation else { return }
        for scan in results { scans[scan.category.id] = scan }
        // A scan that was stopped between categories returns fewer results than the catalog: the
        // missing ones were not scanned, and say so instead of looking empty.
        for category in catalog where category.selection != .emptyTrashOnly && scans[category.id] == nil {
            scans[category.id] = CategoryScan(category: category, items: [], bytes: 0, issues: [], stopped: true)
        }
        rebuildTiles()
        lastScanFinishedAt = .now
        state = .ready
    }

    private func rebuildTiles() {
        let kept = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.isSelected) })
        categories = order.compactMap { id in
            guard let scan = scans[id] else { return nil }
            return tile(for: scan, selected: kept[id])
        }
    }

    private func tile(for scan: CategoryScan, selected: Bool?) -> CategoryTileModel {
        let category = scan.category
        // What macOS manages (System caches and logs) is shown, never selected and never cleaned.
        let initial = !scan.stopped && category.isSelectedByDefault && preselectSafe
        return CategoryTileModel(
            id: category.id, title: category.title,
            note: category.id == .iosBackups ? "Your data, never selected for you" : nil,
            bytes: scan.bytes, itemCount: scan.items.count, selection: category.selection,
            isSelected: (scan.stopped || category.isNeverCleaned) ? false : (selected ?? initial), stopped: scan.stopped,
            issues: scan.issues, inUseCount: scan.items.filter { inUseOwner($0) != nil }.count,
            leftAlone: category.isNeverCleaned,
            excludedCount: scan.items.filter { excludedItems.contains($0.url) }.count,
            excludedBytes: scan.items.filter { excludedItems.contains($0.url) }.reduce(0) { $0 + $1.bytes })
    }

    // MARK: open apps

    /// The running app that owns `item` right now, if any. Before any re-check this is what the scan
    /// saw; after one, the live running set decides, both ways: in use while the owner runs, free
    /// when it doesn't.
    func inUseOwner(_ item: JunkItem) -> String? {
        guard let owner = item.ownerBundleID else { return nil }
        if let running = runningNow[owner] { return running ? owner : nil }
        return item.inUseByBundleID
    }

    /// The regular apps in `running` that hold selected files which would move if the app closed
    /// (never files that would be skipped anyway), largest first.
    ///
    /// Call it at Move to Trash: it first re-checks in-use from what runs now, so an app opened after
    /// the scan is counted once (as a holder), never also in `selectedBytes`. Without a running-apps
    /// provider it can only add protection, for the apps in `running`.
    public func openAppHolders(running: [RunningApp]) -> [OpenAppHolder] {
        #if DEBUG
        // The fixture's owners are sample data: never offer to close a real app for them.
        guard !isFixture else { return [] }
        #endif
        if let live = runningBundleIDs?() {
            recheckInUse(running: live.union(running.map(\.bundleID)))
        } else {
            recheckInUse(running: Set(running.map(\.bundleID)), addOnly: true)
        }
        let apps = Dictionary(running.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        var totals: [String: (bytes: UInt64, count: Int)] = [:]
        for tile in categories where tile.isSelected && !tile.stopped {
            guard let scan = scans[tile.id] else { continue }
            for item in scan.items where !excludedItems.contains(item.url) {
                guard let id = item.ownerBundleID, apps[id] != nil,
                      Unmovable.check(item, category: scan.category, skipping: cleanupSkip, inUseBy: nil) == nil
                else { continue }
                totals[id, default: (0, 0)].bytes += item.bytes
                totals[id, default: (0, 0)].count += 1
            }
        }
        return totals.compactMap { id, total in
            apps[id].map {
                OpenAppHolder(bundleID: id, name: $0.name, bundleURL: $0.bundleURL, bytes: total.bytes, itemCount: total.count)
            }
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    }

    /// Decides in-use again from `running`, for every owner (or only `owners`). An owner that runs is
    /// in use; one that doesn't is free. `clean()` does this itself right before every cleanup.
    /// `addOnly`: only protect owners that run now, never free one (used right before a cleanup, so
    /// it can't move more than the user confirmed).
    public func recheckInUse(running: Set<String>, only owners: Set<String>? = nil, addOnly: Bool = false) {
        let all = Set(scans.values.flatMap { $0.items.compactMap(\.ownerBundleID) })
        for owner in owners.map({ $0.intersection(all) }) ?? all {
            let runs = running.contains(owner)
            if addOnly && !runs { continue }
            runningNow[owner] = runs
        }
        rebuildTiles()
    }

    /// After "Quit apps and clean": asks the apps to quit, re-checks only those apps, and cleans when
    /// exactly the offered amount can move. Otherwise it says what changed and waits for the user.
    /// `skipping`: places that can't be read now, as for `clean(skipping:)`; nil uses `cleanupSkip`.
    public func quitAndCleanFlow(
        _ run: CloseAppsRun, quitter: AppQuitter, timeout: Duration = CloseApps.timeout, promised: UInt64,
        skipping: CleanupSkip? = nil
    ) async -> CloseApps.FlowResult {
        #if DEBUG
        guard !isFixture else {
            return .askAgain(now: selectedBytes, line: "This is a screenshot sample, so no app was closed.")
        }
        #endif
        await run.quitAll(using: quitter, timeout: timeout)
        let offered = Set(run.holders.map(\.bundleID))
        // Without a provider nothing can be verified: trust only the quitter's own answers, so an app
        // is free only if it confirmed it closed. Never treat "unknown" as "all closed".
        let running = runningBundleIDs?()
            ?? Set(run.holders.filter { run.statuses[$0.bundleID] != .closed }.map(\.bundleID))
        recheckInUse(running: running, only: offered)
        run.settle(running: running)
        let now = selectedBytes
        guard now == promised else {
            let stillOpen = run.statuses.values.contains(.stillOpen)
            return .askAgain(
                now: now, line: CloseApps.changedLine(promised: promised, now: now, someStillOpen: stillOpen) ?? "")
        }
        await clean(skipping: skipping, confirmedLimited: true, closedApps: run.closedNames)
        return .cleaned
    }

    // MARK: review files

    /// The Review files list for the selected categories, as if `excluding` were left out. The sheet
    /// edits a draft and calls this on every change; `setExclusions` keeps the result.
    public func review(
        excluding: Set<URL>, skipping: CleanupSkip? = nil, appName: (String) -> String? = { _ in nil }
    ) -> FileReview {
        let skipping = skipping ?? cleanupSkip
        let sections = categories.compactMap { tile -> FileReview.Section? in
            guard tile.isSelected, !tile.stopped, let scan = scans[tile.id] else { return nil }
            let rows = scan.items.map { item -> FileReview.Row in
                let reason = FileReview.disabledReason(
                    item, category: scan.category, skipping: skipping, inUseBy: inUseOwner(item), appName: appName)
                return FileReview.Row(
                    url: item.url, name: item.url.lastPathComponent, bytes: item.bytes, disabledReason: reason,
                    isIncluded: reason == nil && !excluding.contains(item.url))
            }
            .sorted { a, b in
                if (a.disabledReason == nil) != (b.disabledReason == nil) { return a.disabledReason == nil }
                return a.bytes != b.bytes ? a.bytes > b.bytes : a.url.path < b.url.path
            }
            let included = rows.filter(\.isIncluded)
            return FileReview.Section(
                id: tile.id, title: tile.title, rows: rows,
                selectedBytes: included.reduce(0) { $0 + $1.bytes }, selectedCount: included.count)
        }
        return FileReview(sections: sections)
    }

    /// Keeps the files left out in Review files (Done). Unknown files are ignored.
    public func setExclusions(_ urls: Set<URL>) {
        guard case .ready = state else { return }
        let known = Set(scans.values.flatMap { $0.items.map(\.url) })
        excludedItems = urls.intersection(known)
        message = nil
        rebuildTiles()
    }

    public func toggle(_ id: JunkCategoryID) {
        guard case .ready = state, let index = categories.firstIndex(where: { $0.id == id }) else { return }
        let tile = categories[index]
        guard !tile.stopped, tile.selection != .emptyTrashOnly, !tile.leftAlone else { return }
        categories[index].isSelected.toggle()
        message = nil
    }

    // MARK: clean

    /// Moves the selected categories to the Trash. The allowed roots are the folders the scan listed
    /// the items in: each item's parent, which is the category root the scan resolved (the scanner
    /// only lists a root's direct children). The protected paths still apply to every move.
    ///
    /// `skipping`: places that can't be read now; their items are recorded as skipped. With the gate
    /// at `confirmFirst`, nothing happens unless the user confirmed (`confirmedLimited`).
    /// `closedApps`: apps the user let Dustling close first, named in the summary.
    public func clean(skipping: CleanupSkip? = nil, confirmedLimited: Bool = false, closedApps: [String] = []) async {
        let skipping = skipping ?? cleanupSkip
        #if DEBUG
        guard !isFixture else { return }
        #endif
        guard case .ready = state, !isRestoring else { return }
        switch cleanupGate.kind {
        case .refused:
            message = cleanupGate.note
            return
        case .confirmFirst where !confirmedLimited:
            message = cleanupGate.note
            return
        case .allowed, .confirmFirst:
            break
        }
        // Apps may have opened or closed since the last look: decide in-use from what runs now.
        // Only adds protection: an app that opened meanwhile keeps its files, but nothing is freed
        // here, so a cleanup never moves more than the figure the user confirmed.
        if let running = runningBundleIDs?() { recheckInUse(running: running, addOnly: true) }

        var urls: [URL] = []
        var sizes: [URL: UInt64] = [:]
        var extra: [JournalEntry] = []
        var roots = Set<URL>()
        var categoryOf: [String: JunkCategoryID] = [:]
        var urlCategory: [URL: JunkCategoryID] = [:]
        var progress: [JunkCategoryID: CategoryProgress] = [:]
        message = nil
        didPutBack = false
        for tile in categories where tile.isSelected && !tile.stopped {
            guard let scan = scans[tile.id] else { continue }
            progress[tile.id] = CategoryProgress(done: 0, total: 0)
            // Files left out in Review files were never part of the plan: no move, no entry.
            for item in scan.items where !excludedItems.contains(item.url) {
                let path = item.url.path(percentEncoded: false)
                categoryOf[path] = tile.id
                if let unmovable = Unmovable.check(item, category: scan.category, skipping: skipping, inUseBy: inUseOwner(item)) {
                    extra.append(JournalEntry(originalPath: path, bytes: item.bytes, outcome: unmovable.outcome))
                } else {
                    let parent = item.url.deletingLastPathComponent()
                    urls.append(item.url)
                    sizes[item.url] = item.bytes
                    urlCategory[item.url] = tile.id
                    progress[tile.id, default: CategoryProgress(done: 0, total: 0)].total += 1
                    roots.insert(parent)
                }
            }
        }
        guard !urls.isEmpty || !extra.isEmpty else {
            message = "Nothing is selected to move to the Trash."
            return
        }

        categoryProgress = progress
        categoryOutcomes = [:]
        self.closedApps = closedApps
        state = .moving(done: 0, total: urls.count, bytes: 0)
        let runner = self.runner.with(admin: admin())
        let allowedRoots = Array(roots)
        let itemSizes = sizes
        let itemCategories = urlCategory
        let throttle = MoveProgressThrottle()
        let task = Task { [self] () -> RunRecord in
            await runner.run(
                urls, kind: .junkClean, allowedRoots: allowedRoots, extraEntries: extra,
                onItem: { url, outcome in
                    var moved: UInt64 = 0
                    if case .movedToTrash = outcome { moved = itemSizes[url] ?? 0 }
                    guard let batch = throttle.add(movedBytes: moved, category: itemCategories[url]) else { return }
                    Task { @MainActor in self.itemsMoved(batch) }
                })
        }
        cleanTask = task
        let record = await task.value
        cleanTask = nil
        // Every attempt is over: a stopped cleanup records the rest as skipped, so each tile ends.
        categoryProgress = categoryProgress.mapValues { CategoryProgress(done: $0.total, total: $0.total) }
        categoryOutcomes = CategoryOutcome.split(record, categoryOf: categoryOf)
        outcomeCategoryOf = categoryOf
        state = .done(record)
        onRunCompleted()
    }

    private func itemsMoved(_ batch: MoveProgressThrottle.Batch) {
        guard case .moving(let done, let total, let moved) = state else { return }
        for (category, count) in batch.itemsByCategory { categoryProgress[category]?.done += count }
        state = .moving(done: done + batch.items, total: total, bytes: moved + batch.movedBytes)
    }

    // MARK: put everything back

    /// Restores the items the run just made moved to the Trash, and only those: skipped and failed
    /// items were never moved.
    public func putEverythingBack() async throws -> [RestoreOutcome] {
        #if DEBUG
        guard !isFixture else { throw JunkScanModelError.noCleanupToUndo }
        #endif
        guard case .done(let record) = state else { throw JunkScanModelError.noCleanupToUndo }
        guard !didPutBack else { throw JunkScanModelError.alreadyPutBack }
        guard !isRestoring else { throw JunkScanModelError.alreadyPuttingBack }
        let paths = Set(record.entries.compactMap { entry -> String? in
            if case .movedToTrash = entry.outcome { entry.originalPath } else { nil }
        })
        guard !paths.isEmpty else { throw RunJournalError.notRestorable(record.id) }
        let journal = self.journal
        let id = record.id
        let admin = self.admin()
        isRestoring = true
        defer { isRestoring = false }
        do {
            let outcomes = try await Blocking.run { try journal.restore(runID: id, paths: paths, admin: admin) }
            // Only onto the summary of this same run.
            if case .done(let shown) = state, shown.id == id {
                restoreOutcomes = outcomes
                for case .restored(let path) in outcomes {
                    if let id = outcomeCategoryOf[path] { categoryOutcomes[id]?.restoredCount += 1 }
                }
                // Once something came back the run is put back; if nothing did, it can be tried again.
                didPutBack = outcomes.contains { if case .restored = $0 { true } else { false } }
            }
            onRunCompleted()
            return outcomes
        } catch {
            onRunCompleted()
            throw error
        }
    }
}

#if DEBUG
extension JunkScanModel {
    /// What the screenshot fixture shows.
    public enum FixturePhase: Sendable {
        /// Results with the default selection.
        case ready
        /// Scanning: the first `finished` categories are in, the counter shows `progress`.
        case scanning(ScanProgress, finished: Int)
        /// The summary of this run (its entries' paths are the fixture items' paths).
        case done(RunRecord)
        /// A cleanup of the selected tiles that has moved `done` of their items so far.
        case moving(done: Int)
    }

    /// Screenshot fixture (DEBUG only): shows these scan results without reading the disk. The model
    /// then refuses to scan, clean or put back anything.
    public func showFixture(_ results: [CategoryScan], phase: FixturePhase) {
        isFixture = true
        generation += 1
        order = results.map(\.category.id)
        scans = [:]
        categories = []
        excludedItems = []
        restoreOutcomes = nil
        message = nil
        categoryProgress = [:]
        categoryOutcomes = [:]
        switch phase {
        case .ready:
            for scan in results { scans[scan.category.id] = scan }
            rebuildTiles()
            lastScanFinishedAt = .now
            state = .ready
        case .scanning(let progress, let finished):
            for scan in results.prefix(finished) { scans[scan.category.id] = scan }
            rebuildTiles()
            state = .scanning(progress)
        case .done(let record):
            for scan in results { scans[scan.category.id] = scan }
            rebuildTiles()
            lastScanFinishedAt = .now
            var categoryOf: [String: JunkCategoryID] = [:]
            for scan in results {
                for item in scan.items { categoryOf[item.url.path(percentEncoded: false)] = scan.category.id }
            }
            categoryOutcomes = CategoryOutcome.split(record, categoryOf: categoryOf)
            outcomeCategoryOf = categoryOf
            for tile in categories where tile.isSelected {
                categoryProgress[tile.id] = CategoryProgress(done: tile.itemCount, total: tile.itemCount)
            }
            state = .done(record)
        case .moving(let done):
            for scan in results { scans[scan.category.id] = scan }
            rebuildTiles()
            lastScanFinishedAt = .now
            var total = 0
            var moved: UInt64 = 0
            for tile in categories where tile.isSelected {
                guard let scan = scans[tile.id] else { continue }
                let finished = min(scan.items.count, max(0, done - total))
                categoryProgress[tile.id] = CategoryProgress(done: finished, total: scan.items.count)
                moved += scan.items.prefix(finished).reduce(0) { $0 + $1.bytes }
                total += scan.items.count
            }
            state = .moving(done: min(done, total), total: total, bytes: moved)
        }
    }

    /// Screenshot fixture: Put everything back is running (it never finishes).
    public func showFixtureRestoring() {
        guard isFixture else { return }
        isRestoring = true
    }
}
#endif
