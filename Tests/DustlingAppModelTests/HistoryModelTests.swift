import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

@MainActor
struct HistoryModelTests {
    /// A run whose one item sits in a fake Trash folder, so the journal still calls it restorable.
    private func trashedRun(
        _ rig: ModelRig, name: String, original: String, ago: TimeInterval, kind: RunKind = .junkClean
    ) throws -> RunRecord {
        let trashed = try rig.file(rig.environment.userTrash.appending(path: name), bytes: 100)
        let entry = JournalEntry(
            originalPath: original, bytes: 100, outcome: .movedToTrash(trashedPath: trashed.path))
        let run = RunRecord(startedAt: Date().addingTimeInterval(-ago), kind: kind, entries: [entry], restorable: true)
        try rig.journal.save(run)
        return run
    }

    @Test func historyMarksRunsBeforeLastEmptyAsNotRestorable() async throws {
        let rig = try ModelRig()
        let old = try trashedRun(rig, name: "old.txt", original: rig.root.appending(path: "orig/old.txt").path, ago: 3 * 3600)
        let emptied = RunRecord(
            startedAt: Date().addingTimeInterval(-2 * 3600), kind: .emptyTrash,
            entries: [JournalEntry(originalPath: "/x/gone", bytes: 5, outcome: .deleted)], restorable: false)
        try rig.journal.save(emptied)
        let new = try trashedRun(rig, name: "new.txt", original: rig.root.appending(path: "orig/new.txt").path, ago: 3600)
        let model = HistoryModel(journal: rig.journal)

        await model.refresh()

        #expect(model.runs.map(\.id) == [new.id, emptied.id, old.id])   // newest first
        let lastEmpty = try #require(model.lastEmptyTrash)
        #expect(abs(lastEmpty.timeIntervalSince(emptied.startedAt)) < 1)
        let newRow = try #require(model.runs.first { $0.id == new.id })
        #expect(newRow.restorable)
        #expect(newRow.chip == "Can be restored")
        let oldRow = try #require(model.runs.first { $0.id == old.id })
        #expect(!oldRow.restorable)
        #expect(oldRow.chip == "Trash emptied")
        #expect(model.runs.first { $0.id == emptied.id }?.chip == nil)
        #expect(model.allItems.first { $0.runID == old.id }?.restorable == false)
        #expect(model.allItems.first { $0.runID == new.id }?.restorable == true)

        await #expect(throws: HistoryModelError.trashWasEmptied) {
            _ = try await model.restore(runID: old.id)
        }
    }

    @Test func searchFiltersAllItems() async throws {
        let rig = try ModelRig()
        _ = try trashedRun(rig, name: "alpha.txt", original: "/orig/Alpha Notes.txt", ago: 100)
        _ = try trashedRun(rig, name: "beta.txt", original: "/orig/beta.log", ago: 200)
        let model = HistoryModel(journal: rig.journal)
        await model.refresh()
        #expect(model.allItems.count == 2)
        #expect(model.filteredItems.count == 2)

        model.search = "alpha"
        #expect(model.filteredItems.map(\.name) == ["Alpha Notes.txt"])
        model.search = ".log"
        #expect(model.filteredItems.map(\.name) == ["beta.log"])
        model.search = "nothing like this"
        #expect(model.filteredItems.isEmpty)
        model.search = ""
        model.itemFilter = .restorable
        #expect(model.filteredItems.count == 2)
    }

    @Test func logLinesComeFromTheRecordAndStartupTogglesReadAsTurnedOff() async throws {
        let rig = try ModelRig()
        let run = RunRecord(
            startedAt: Date(), kind: .startupChange,
            entries: [
                JournalEntry(originalPath: "/a/on.plist", bytes: 0, outcome: .skipped(reason: "enabled")),
                JournalEntry(originalPath: "/a/off.plist", bytes: 0, outcome: .skipped(reason: "disabled")),
                JournalEntry(originalPath: "/a/bad.plist", bytes: 0, outcome: .failed(reason: "nope")),
            ], restorable: false)
        try rig.journal.save(run)
        let model = HistoryModel(journal: rig.journal)
        await model.refresh()

        let lines = model.logLines(for: run.id)
        #expect(lines.map(\.status) == ["Turned on", "Turned off", "Failed: nope"])
        #expect(lines.map(\.path) == ["/a/on.plist", "/a/off.plist", "/a/bad.plist"])
        #expect(model.runs.first?.chip == nil)
        #expect(model.logLines(for: UUID()).isEmpty)
    }

    @Test func restorePutsItemsBackAndNotifies() async throws {
        let rig = try ModelRig()
        let original = rig.root.appending(path: "orig/file.txt")
        let run = try trashedRun(rig, name: "file.txt", original: original.path, ago: 60)
        let completed = Counter()
        let model = HistoryModel(journal: rig.journal, onRunCompleted: { completed.bump() })
        await model.refresh()

        let outcomes = try await model.restore(runID: run.id)

        #expect(outcomes == [.restored(original.path)])
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(completed.value == 1)
        #expect(model.runs.first?.restorable == false)
        #expect(model.logLines(for: run.id).first?.status == "Put back")
        await #expect(throws: RunJournalError.notRestorable(run.id)) {
            _ = try await model.restore(runID: run.id)
        }
        #expect(completed.value == 2)
    }

    @Test func unreadableRecordsAreReported() async throws {
        let rig = try ModelRig()
        try FileManager.default.createDirectory(at: rig.environment.historyDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: rig.environment.historyDirectory.appending(path: "broken.json"))
        let model = HistoryModel(journal: rig.journal)
        await model.refresh()
        #expect(model.unreadableRecords.count == 1)
    }

    @Test func restoreOfRunBeforeLastEmptyIsRefusedEvenWithoutAPriorRefresh() async throws {
        let rig = try ModelRig()
        let original = rig.root.appending(path: "orig/old.txt")
        let old = try trashedRun(rig, name: "old.txt", original: original.path, ago: 3 * 3600)
        try rig.journal.save(RunRecord(
            startedAt: Date().addingTimeInterval(-3600), kind: .emptyTrash, entries: [], restorable: false))
        let model = HistoryModel(journal: rig.journal)   // never refreshed

        await #expect(throws: HistoryModelError.trashWasEmptied) {
            _ = try await model.restore(runID: old.id)
        }
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }
}
