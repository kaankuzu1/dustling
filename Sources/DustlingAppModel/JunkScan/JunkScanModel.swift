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

public enum JunkScanModelError: Error, Equatable, LocalizedError, Sendable {
    case noCleanupToUndo
    case alreadyPutBack

    public var errorDescription: String? {
        switch self {
        case .noCleanupToUndo: "There is no cleanup to put back."
        case .alreadyPutBack: "This cleanup was already put back."
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
        case problem(String)
    }

    public private(set) var state: State = .idle
    public private(set) var categories: [CategoryTileModel] = []
    /// What the last Put everything back did, item by item.
    public private(set) var restoreOutcomes: [RestoreOutcome]?
    /// A plain sentence about the last action that did nothing (e.g. nothing selected); nil otherwise.
    public private(set) var message: String?
    /// True once the run just made was put back (allowed once per run).
    public private(set) var didPutBack = false
    /// Applied at the next scan (the "Preselect safe categories" setting).
    public var preselectSafe: Bool

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

    /// What a clean would move: selected, fully scanned categories that don't need admin, minus the
    /// items of apps that are open right now.
    public var selectedBytes: UInt64 {
        categories.reduce(0) { sum, tile in
            guard tile.isSelected, !tile.stopped, let scan = scans[tile.id], !scan.category.requiresAdmin else { return sum }
            return sum + scan.items.filter { $0.inUseByBundleID == nil }.reduce(0) { $0 + $1.bytes }
        }
    }

    public var summary: CleanSummary? {
        if case .done(let record) = state { CleanSummary(record) } else { nil }
    }

    /// True while the run just made can still be put back (once per run).
    public var canPutBack: Bool {
        if case .done(let record) = state { !didPutBack && record.restorable } else { false }
    }

    public var isBusy: Bool {
        switch state {
        case .scanning, .moving: true
        default: false
        }
    }

    // MARK: scan

    public func scan() {
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
        // Admin-only categories wait for the cleanup helper: shown with their size, never selected.
        let initial = !scan.stopped && !category.requiresAdmin && category.selection == .preselected && preselectSafe
        return CategoryTileModel(
            id: category.id, title: category.title,
            note: category.requiresAdmin
                ? "Needs the cleanup helper"
                : (category.id == .iosBackups ? "Your data, never selected for you" : nil),
            bytes: scan.bytes, itemCount: scan.items.count, selection: category.selection,
            isSelected: (scan.stopped || category.requiresAdmin) ? false : (selected ?? initial), stopped: scan.stopped,
            issues: scan.issues, inUseCount: scan.items.filter { $0.inUseByBundleID != nil }.count)
    }

    public func toggle(_ id: JunkCategoryID) {
        guard case .ready = state, let index = categories.firstIndex(where: { $0.id == id }) else { return }
        let tile = categories[index]
        guard !tile.stopped, tile.selection != .emptyTrashOnly, scans[id]?.category.requiresAdmin != true else { return }
        categories[index].isSelected.toggle()
    }

    // MARK: clean

    /// Moves the selected categories to the Trash. The allowed roots are the category folders the
    /// scan really resolved (the same rule as `dustling-cli clean`), never the items' own parents.
    public func clean() async {
        guard case .ready = state else { return }

        var urls: [URL] = []
        var sizes: [URL: UInt64] = [:]
        var extra: [JournalEntry] = []
        var roots = Set<URL>()
        message = nil
        didPutBack = false
        for tile in categories where tile.isSelected && !tile.stopped {
            guard let scan = scans[tile.id] else { continue }
            for item in scan.items {
                let path = item.url.path(percentEncoded: false)
                if let owner = item.inUseByBundleID {
                    extra.append(JournalEntry(
                        originalPath: path, bytes: item.bytes, outcome: .skipped(reason: "in use by \(owner)")))
                } else if scan.category.requiresAdmin {
                    // Unreachable while admin tiles can't be selected; kept as defence.
                    extra.append(JournalEntry(originalPath: path, bytes: item.bytes, outcome: .needsAdmin))
                } else {
                    let parent = item.url.deletingLastPathComponent()
                    if scan.category.isDeclaredRoot(parent) {
                        urls.append(item.url)
                        sizes[item.url] = item.bytes
                        roots.insert(parent)
                    } else {
                        extra.append(JournalEntry(
                            originalPath: path, bytes: item.bytes, outcome: .skipped(reason: "outside the cleanup area")))
                    }
                }
            }
        }
        guard !urls.isEmpty || !extra.isEmpty else {
            message = "Nothing is selected to move to the Trash."
            return
        }

        state = .moving(done: 0, total: urls.count, bytes: 0)
        let runner = self.runner
        let allowedRoots = Array(roots)
        let itemSizes = sizes
        let task = Task { [self] () -> RunRecord in
            await runner.run(
                urls, kind: .junkClean, allowedRoots: allowedRoots, extraEntries: extra,
                onItem: { url, outcome in
                    let bytes = itemSizes[url] ?? 0
                    Task { @MainActor in self.itemMoved(outcome, bytes: bytes) }
                })
        }
        cleanTask = task
        let record = await task.value
        cleanTask = nil
        state = .done(record)
        onRunCompleted()
    }

    private func itemMoved(_ outcome: DeletionOutcome, bytes: UInt64) {
        guard case .moving(let done, let total, let moved) = state else { return }
        var movedNow = moved
        if case .movedToTrash = outcome { movedNow += bytes }
        state = .moving(done: done + 1, total: total, bytes: movedNow)
    }

    // MARK: put everything back

    /// Restores the items the run just made moved to the Trash, and only those: skipped and failed
    /// items were never moved.
    public func putEverythingBack() async throws -> [RestoreOutcome] {
        guard case .done(let record) = state else { throw JunkScanModelError.noCleanupToUndo }
        guard !didPutBack else { throw JunkScanModelError.alreadyPutBack }
        let paths = Set(record.entries.compactMap { entry -> String? in
            if case .movedToTrash = entry.outcome { entry.originalPath } else { nil }
        })
        guard !paths.isEmpty else { throw RunJournalError.notRestorable(record.id) }
        let journal = self.journal
        let id = record.id
        do {
            let outcomes = try await Blocking.run { try journal.restore(runID: id, paths: paths) }
            restoreOutcomes = outcomes
            didPutBack = true
            onRunCompleted()
            return outcomes
        } catch {
            onRunCompleted()
            throw error
        }
    }
}
