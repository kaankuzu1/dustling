import DustlingCore
import Foundation
import Observation

public struct RunRow: Identifiable, Equatable, Sendable {
    public let record: RunRecord
    public let title: String
    /// "Can be restored", "Trash emptied", or nil when the run moved nothing to the Trash.
    public let chip: String?
    public let restorable: Bool
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
    public let path: String
    public let bytes: UInt64
    public let status: String
    /// This item can be put back from the Trash right now.
    public let restorable: Bool
    public var id: String { runID.uuidString + "|" + path }
    public var name: String { URL(filePath: path).lastPathComponent }
}

public enum HistoryItemFilter: Sendable, CaseIterable {
    case restorable, all
}

public enum HistoryModelError: Error, Equatable, LocalizedError, Sendable {
    case trashWasEmptied

    public var errorDescription: String? {
        "The Trash was emptied after this run, so its items can't be put back."
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

    @ObservationIgnored private let journal: RunJournal
    @ObservationIgnored private let onRunCompleted: @MainActor () -> Void
    @ObservationIgnored private var generation = 0

    public init(journal: RunJournal, onRunCompleted: @escaping @MainActor () -> Void = {}) {
        self.journal = journal
        self.onRunCompleted = onRunCompleted
    }

    public func refresh() async {
        generation += 1
        let mine = generation
        isLoading = true
        let journal = self.journal
        let snapshot = await Task.detached(priority: .userInitiated) { () -> Snapshot in
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
        }.value
        guard mine == generation else { return }
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
        runs = sorted.map { Self.row($0, lastEmpty: lastEmpty) }
        let restorableRuns = Set(runs.filter(\.restorable).map(\.id))
        allItems = sorted.flatMap { run in
            run.entries.filter { !$0.originalPath.hasPrefix("<") }.map { entry in
                HistoryItem(
                    runID: run.id, runTitle: Self.title(run.kind), runDate: run.startedAt,
                    path: entry.originalPath, bytes: entry.bytes, status: Self.status(entry, in: run.kind),
                    restorable: restorableRuns.contains(run.id) && RunJournal.isRestorable(entry))
            }
        }
    }

    private static func row(_ run: RunRecord, lastEmpty: Date?) -> RunRow {
        let movedSomething = run.entries.contains { if case .movedToTrash = $0.outcome { true } else { false } }
        let emptiedSince = lastEmpty.map { run.startedAt < $0 } ?? false
        let restorable = run.restorable && !emptiedSince
        let chip: String? = restorable ? "Can be restored" : (movedSomething && emptiedSince ? "Trash emptied" : nil)
        return RunRow(
            record: run, title: title(run.kind), chip: chip, restorable: restorable,
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

    // MARK: restore

    /// Puts items back from the Trash. `paths` limits it to those original paths. Throws
    /// `HistoryModelError.trashWasEmptied` for a run older than the last Empty Trash, and the
    /// journal's own errors (`notRestorable`, `saveFailed`, ...) otherwise. Refreshes afterwards
    /// and calls `onRunCompleted` whenever a restore was attempted.
    public func restore(runID: UUID, paths: Set<String>? = nil) async throws -> [RestoreOutcome] {
        if !runs.contains(where: { $0.id == runID }) { await refresh() }
        if let run = runs.first(where: { $0.id == runID }), let emptied = lastEmptyTrash,
           run.record.startedAt < emptied {
            throw HistoryModelError.trashWasEmptied
        }
        let journal = self.journal
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[RestoreOutcome], Error> in
            Result { try journal.restore(runID: runID, paths: paths) }
        }.value
        await refresh()
        onRunCompleted()
        return try result.get()
    }
}
