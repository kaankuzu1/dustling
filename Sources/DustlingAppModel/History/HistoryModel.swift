import DustlingCore
import Foundation
import Observation

public struct RunRow: Identifiable, Equatable, Sendable {
    public let record: RunRecord
    public let title: String
    /// "Can be restored", "Trash emptied", or nil when the run moved nothing to the Trash.
    public let chip: String?
    public let restorable: Bool
    /// The run is still marked in progress: "Still running" while Dustling is working, otherwise
    /// "Interrupted" (it never finished). Such a run is never put back.
    public let inProgress: Bool
    public let itemCount: Int
    public let bytes: UInt64
    public var id: UUID { record.id }
    public var date: Date { record.startedAt }
}

public struct LogLine: Identifiable, Equatable, Sendable {
    public let path: String
    public let bytes: UInt64
    /// In plain words: "Moved to Trash", "Turned off", "Put back", ...
    public let status: String
    public let restored: Bool
    public var id: String { path + "|" + status }
}

public struct HistoryItem: Identifiable, Equatable, Sendable {
    public let runID: UUID
    public let runTitle: String
    public let runDate: Date
    public let runKind: RunKind
    public let path: String
    public let bytes: UInt64
    public let status: String
    /// This item can be put back from the Trash right now.
    public let restorable: Bool
    /// The journal entry as saved, for the screen's status column.
    public let entry: JournalEntry
    public var id: String { runID.uuidString + "|" + path }
    public var name: String { URL(filePath: path).lastPathComponent }
}

public enum HistoryItemFilter: Sendable, CaseIterable {
    case restorable, all
}

public enum HistoryModelError: Error, Equatable, LocalizedError, Sendable {
    case trashWasEmptied
    /// Without Full Disk Access macOS won't let Dustling take anything out of the Trash.
    case cantTakeOutOfTrash
    /// The run is still marked in progress (running now, or interrupted before it finished).
    case runInProgress
    /// A cleanup, uninstall, startup change or retry is running.
    case busy
    #if DEBUG
    /// The DEBUG screenshot fixture is showing; nothing is restored.
    case fixture
    #endif

    public var errorDescription: String? {
        switch self {
        case .trashWasEmptied: "The Trash was emptied after this run, so its items can't be put back."
        case .cantTakeOutOfTrash: "Dustling can't take things out of the Trash without Full Disk Access."
        case .runInProgress: "This run hasn't finished, so its items can't be put back yet."
        case .busy: "Wait until the current cleanup or change finishes, then put back."
        #if DEBUG
        case .fixture: "This is a screenshot sample, so nothing was put back."
        #endif
        }
    }
}

/// Drives the History screen: a timeline of runs, what each one did, and Put back.
@MainActor @Observable
public final class HistoryModel {
    public private(set) var runs: [RunRow] = []
    public private(set) var lastEmptyTrash: Date?
    public private(set) var allItems: [HistoryItem] = []
    /// History files that could not be read; the UI says so instead of hiding them.
    public private(set) var unreadableRecords: [URL] = []
    /// Set when the history could not be listed or its restorable flags could not be refreshed.
    public private(set) var problem: String?
    public private(set) var isLoading = false
    public var search = ""
    public var itemFilter: HistoryItemFilter = .all
    /// False without Full Disk Access: macOS then won't let Dustling take anything out of the Trash,
    /// so the screen offers Show in Trash and `restore` refuses.
    public var canTakeOutOfTrash = true
    /// True while items are being put back.
    public private(set) var isRestoring = false
    /// How many items the restore running now asked for.
    public private(set) var restoringCount = 0
    /// What the last restore did, for the screen's banner. Cleared by `dismissRestore()`.
    public private(set) var lastRestore: HistoryScreen.RestoreSummary?

    @ObservationIgnored private let journal: RunJournal
    @ObservationIgnored private let logger: RunLogger?
    /// The home folder, shown as `~` in the bug report.
    public let home: URL?
    @ObservationIgnored private let onRunCompleted: @MainActor () -> Void
    @ObservationIgnored private var generation = 0
    /// True while another tool is working (a cleanup, uninstall, startup change or retry): Put back
    /// waits, and runs still marked in progress read "Still running" instead of "Interrupted".
    @ObservationIgnored public var isOtherWorkBusy: @MainActor () -> Bool = { false }
    #if DEBUG
    @ObservationIgnored public private(set) var isFixture = false
    #endif

    public init(
        journal: RunJournal, logger: RunLogger? = nil, home: URL? = nil,
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.journal = journal
        self.logger = logger
        self.home = home
        self.onRunCompleted = onRunCompleted
    }

    private var fixtureOn: Bool {
        #if DEBUG
        return isFixture
        #else
        return false
        #endif
    }

    public func refresh() async {
        guard !fixtureOn else { return }
        generation += 1
        let mine = generation
        isLoading = true
        let journal = self.journal
        let snapshot = await Blocking.run { () -> Snapshot in
            var problem: String?
            do { try journal.refreshRestorability() } catch {
                problem = "Dustling couldn't update which cleanups can be put back: \(error.localizedDescription)"
            }
            do {
                return Snapshot(
                    records: try journal.all(), unreadable: journal.unreadableRecords(), problem: problem)
            } catch {
                return Snapshot(
                    records: [], unreadable: journal.unreadableRecords(),
                    problem: "Dustling couldn't read its history: \(error.localizedDescription)")
            }
        }
        guard mine == generation, !fixtureOn else { return }
        isLoading = false
        problem = snapshot.problem
        unreadableRecords = snapshot.unreadable
        publish(snapshot.records)
    }

    private struct Snapshot: Sendable {
        let records: [RunRecord]
        let unreadable: [URL]
        let problem: String?
    }

    private func publish(_ records: [RunRecord]) {
        let sorted = records.sorted { $0.startedAt > $1.startedAt }
        let lastEmpty = sorted.first { $0.kind == .emptyTrash }?.startedAt
        lastEmptyTrash = lastEmpty
        runs = sorted.map { Self.row($0, lastEmpty: lastEmpty, busy: isOtherWorkBusy()) }
        let restorableRuns = Set(runs.filter(\.restorable).map(\.id))
        allItems = sorted.flatMap { run in
            run.entries.filter { !$0.originalPath.hasPrefix("<") }.map { entry in
                HistoryItem(
                    runID: run.id, runTitle: HistoryScreen.runTitle(run), runDate: run.startedAt, runKind: run.kind,
                    path: entry.originalPath, bytes: entry.bytes, status: Self.status(entry, in: run.kind),
                    restorable: restorableRuns.contains(run.id) && isRestorable(entry), entry: entry)
            }
        }
    }

    private static func row(_ run: RunRecord, lastEmpty: Date?, busy: Bool) -> RunRow {
        let movedSomething = run.entries.contains { if case .movedToTrash = $0.outcome { true } else { false } }
        let emptiedSince = lastEmpty.map { run.startedAt < $0 } ?? false
        let restorable = run.restorable && !emptiedSince && !run.inProgress
        let chip: String?
        if run.inProgress {
            chip = busy ? "Still running" : "Interrupted"
        } else {
            chip = restorable ? "Can be restored" : (movedSomething && emptiedSince ? "Trash emptied" : nil)
        }
        return RunRow(
            record: run, title: title(run.kind), chip: chip, restorable: restorable, inProgress: run.inProgress,
            itemCount: run.entries.filter { !$0.originalPath.hasPrefix("<") }.count, bytes: run.bytesMovedToTrash)
    }

    static func title(_ kind: RunKind) -> String {
        switch kind {
        case .junkClean: "Junk cleanup"
        case .uninstall(let name): "Uninstalled \(name)"
        case .emptyTrash: "Emptied the Trash"
        case .startupChange: "Startup change"
        }
    }

    private static func status(_ entry: JournalEntry, in kind: RunKind) -> String {
        if entry.restored { return "Put back" }
        if entry.gone { return "No longer in the Trash" }
        return OutcomePresentation.text(entry.outcome, in: kind)
    }

    /// The journal's check, except in the DEBUG fixture (whose items aren't on disk).
    private func isRestorable(_ entry: JournalEntry) -> Bool {
        #if DEBUG
        if isFixture { return !entry.restored && !entry.gone && { if case .movedToTrash = entry.outcome { true } else { false } }() }
        #endif
        return RunJournal.isRestorable(entry)
    }

    // MARK: items

    /// `allItems` narrowed by the filter and the search text (matches the file name or path).
    public var filteredItems: [HistoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return allItems.filter { item in
            if itemFilter == .restorable && !item.restorable { return false }
            return query.isEmpty || item.path.localizedStandardContains(query)
                || item.runTitle.localizedStandardContains(query)
        }
    }

    /// What a run did, line by line, read from the saved record (not the text log).
    public func logLines(for runID: UUID) -> [LogLine] {
        guard let run = runs.first(where: { $0.id == runID })?.record else { return [] }
        return run.entries.map { entry in
            LogLine(
                path: entry.originalPath, bytes: entry.bytes, status: Self.status(entry, in: run.kind),
                restored: entry.restored)
        }
    }

    // MARK: log

    /// The log file the run was written to (nil without a logger).
    public func logFile(for runID: UUID) -> URL? {
        guard let logger, let run = runs.first(where: { $0.id == runID })?.record else { return nil }
        return logger.file(for: run.startedAt)
    }

    /// "Copy for a bug report": the run's own log lines, with the home folder as `~`.
    public func bugReport(for runID: UUID) async -> String {
        guard let run = runs.first(where: { $0.id == runID })?.record else { return "" }
        let file = logFile(for: runID)
        let text = await Blocking.run { () -> String? in
            guard let file else { return nil }
            return try? String(contentsOf: file, encoding: .utf8)
        }
        return HistoryScreen.bugReport(logText: text, record: run, home: home?.path(percentEncoded: false) ?? "")
    }

    // MARK: restore

    /// Puts items back from the Trash. `paths` limits it to those original paths. Throws
    /// `cantTakeOutOfTrash` without Full Disk Access, `HistoryModelError.trashWasEmptied` for a run
    /// older than the last Empty Trash, and the journal's own errors (`notRestorable`, `saveFailed`,
    /// ...) otherwise. Refreshes afterwards and calls `onRunCompleted` whenever a restore was attempted.
    public func restore(runID: UUID, paths: Set<String>? = nil) async throws -> [RestoreOutcome] {
        #if DEBUG
        if fixtureOn { throw HistoryModelError.fixture }
        #endif
        guard canTakeOutOfTrash else { throw HistoryModelError.cantTakeOutOfTrash }
        guard !isRestoring else { return [] }
        guard !isOtherWorkBusy() else { throw HistoryModelError.busy }
        // Busy before the first await, so a second restore started meanwhile is refused.
        isRestoring = true
        restoringCount = paths?.count ?? 0
        defer { isRestoring = false }
        // Always from the journal as it is now: a run's in-progress flag may have changed.
        await refresh()
        if runs.first(where: { $0.id == runID })?.inProgress == true { throw HistoryModelError.runInProgress }
        if let run = runs.first(where: { $0.id == runID }), let emptied = lastEmptyTrash,
           run.record.startedAt < emptied {
            throw HistoryModelError.trashWasEmptied
        }
        restoringCount = paths?.count ?? runs.first { $0.id == runID }.map { row in
            row.record.entries.filter { RunJournal.isRestorable($0) }.count
        } ?? 0
        let journal = self.journal
        let result = await Blocking.run { () -> Result<[RestoreOutcome], Error> in
            Result { try journal.restore(runID: runID, paths: paths) }
        }
        isRestoring = false
        if case .success(let outcomes) = result { lastRestore = HistoryScreen.restoreSummary(outcomes) }
        await refresh()
        onRunCompleted()
        return try result.get()
    }

    /// Puts back the checked items of the All items table, run by run. A run that can't be restored
    /// any more turns into a failed outcome for each of its items, so every item is accounted for.
    @discardableResult
    public func restore(items: [HistoryItem]) async throws -> [RestoreOutcome] {
        #if DEBUG
        if fixtureOn { throw HistoryModelError.fixture }
        #endif
        guard canTakeOutOfTrash else { throw HistoryModelError.cantTakeOutOfTrash }
        guard !isRestoring, !items.isEmpty else { return [] }
        guard !isOtherWorkBusy() else { throw HistoryModelError.busy }
        // Busy before the first await, so a second restore started meanwhile is refused.
        isRestoring = true
        restoringCount = items.count
        defer { isRestoring = false }
        await refresh()
        let live = Set(runs.filter(\.inProgress).map(\.id))
        let byRun = Dictionary(grouping: items, by: \.runID)
        let emptied = lastEmptyTrash
        let journal = self.journal
        var outcomes: [RestoreOutcome] = []
        for (runID, chosen) in byRun.sorted(by: { $0.value[0].runDate > $1.value[0].runDate }) {
            let paths = Set(chosen.map(\.path))
            if live.contains(runID) {
                let reason = HistoryModelError.runInProgress.localizedDescription
                outcomes += paths.sorted().map { .failed($0, reason: reason) }
                continue
            }
            if let emptied, chosen[0].runDate < emptied {
                let reason = HistoryModelError.trashWasEmptied.localizedDescription
                outcomes += paths.sorted().map { .failed($0, reason: reason) }
                continue
            }
            let result = await Blocking.run { () -> Result<[RestoreOutcome], Error> in
                Result { try journal.restore(runID: runID, paths: paths) }
            }
            switch result {
            case .success(let done): outcomes += done
            case .failure(let error):
                if case RunJournalError.saveFailed(let done, _) = error { outcomes += done }
                let reported = Set(outcomes.map(Self.path))
                outcomes += paths.subtracting(reported).sorted().map { .failed($0, reason: error.localizedDescription) }
            }
        }
        isRestoring = false
        lastRestore = HistoryScreen.restoreSummary(outcomes)
        await refresh()
        onRunCompleted()
        return outcomes
    }

    private static func path(_ outcome: RestoreOutcome) -> String {
        switch outcome {
        case .restored(let p), .conflict(let p), .missingFromTrash(let p), .failed(let p, _): p
        }
    }

    public func dismissRestore() {
        lastRestore = nil
    }

    #if DEBUG
    /// DEBUG screenshots only: shows `records` as if read from History. While on, `refresh` and
    /// `restore` refuse, so nothing is read from or written to the disk.
    public func showFixture(_ records: [RunRecord]) {
        isFixture = true
        isLoading = false
        problem = nil
        unreadableRecords = []
        publish(records)
    }

    /// DEBUG screenshots only.
    public func showFixtureRestore(_ summary: HistoryScreen.RestoreSummary?, restoring: Int = 0) {
        lastRestore = summary
        isRestoring = restoring > 0
        restoringCount = restoring
    }
    #endif
}
