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

    @Test func aRunStillInProgressIsNeverPutBack() async throws {
        let rig = try ModelRig()
        try FileManager.default.createDirectory(at: rig.root.appending(path: "orig"), withIntermediateDirectories: true)
        let original = rig.root.appending(path: "orig/live.txt").path
        var run = try trashedRun(rig, name: "live.txt", original: original, ago: 60)
        run.inProgress = true
        try rig.journal.save(run)
        let model = HistoryModel(journal: rig.journal)
        await model.refresh()
        let row = try #require(model.runs.first)
        #expect(!row.restorable)
        #expect(row.chip == "Interrupted")
        await #expect(throws: HistoryModelError.runInProgress) { _ = try await model.restore(runID: run.id) }
        let item = try #require(model.allItems.first)
        let outcomes = try await model.restore(items: [item])
        #expect(outcomes == [.failed(original, reason: HistoryModelError.runInProgress.localizedDescription)])
        #expect(!FileManager.default.fileExists(atPath: original))

        model.isOtherWorkBusy = { true }
        await model.refresh()
        #expect(model.runs.first?.chip == "Still running")

        // Once recovery marks it finished, it can be put back.
        #expect(try CleanupRunner.recoverInterrupted(journal: rig.journal, quietFor: 0) == [run.id])
        #expect(try rig.journal.all().first?.inProgress == false)
        await #expect(throws: HistoryModelError.busy) { _ = try await model.restore(runID: run.id) }
        model.isOtherWorkBusy = { false }
        _ = try await model.restore(runID: run.id)
        #expect(FileManager.default.fileExists(atPath: original))
    }

    @Test func onlyOneRestoreRunsAtATime() async throws {
        let rig = try ModelRig()
        try FileManager.default.createDirectory(at: rig.root.appending(path: "orig"), withIntermediateDirectories: true)
        let original = rig.root.appending(path: "orig/once.txt").path
        let run = try trashedRun(rig, name: "once.txt", original: original, ago: 60)
        let model = HistoryModel(journal: rig.journal)
        await model.refresh()
        let item = try #require(model.allItems.first)

        // Started back to back: the second sees the first as busy, before either reaches the journal.
        async let first = model.restore(runID: run.id)
        async let second = model.restore(items: [item])
        let (a, b) = try await (first, second)
        #expect(a.count + b.count == 1)
        #expect(a == [.restored(original)] || b == [.restored(original)])
        #expect(FileManager.default.fileExists(atPath: original))
        #expect(!model.isRestoring)
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

    @Test func putBackAsksForThePasswordForAFolderTheUserCantChange() async throws {
        let rig = try ModelRig()
        let folder = rig.root.appending(path: "orig")
        let original = try rig.file(folder.appending(path: "file.txt"), bytes: 100)
        // Moved by the runner, so the journal records who owned the item (Put back needs that).
        let record = await rig.runner().run([original], kind: .junkClean, allowedRoots: [folder], onItem: { _, _ in })
        let shell = FakeAdminShell(.cancelled)
        let model = HistoryModel(journal: rig.journal)
        model.admin = { rig.admin(shell) }
        await model.refresh()
        try rig.lockFolder(folder)
        defer { rig.unlockFolder(folder) }

        let outcomes = try await model.restore(runID: record.id)

        #expect(shell.prompts == [AdminMover.restorePrompt(count: 1)])
        #expect(outcomes == [.failed(original.path, reason: RunJournal.putBackNeedsPasswordReason)])
        // The checked-items route passes it too: one password box per run.
        let items = try await model.restore(items: model.allItems.filter { $0.runID == record.id })
        #expect(shell.prompts.count == 2)
        #expect(items == outcomes)
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

    @Test func restoreIsRefusedWithoutTrashAccess() async throws {
        let rig = try ModelRig()
        let original = rig.root.appending(path: "orig/file.txt")
        let run = try trashedRun(rig, name: "file.txt", original: original.path, ago: 60)
        let model = HistoryModel(journal: rig.journal)
        model.canTakeOutOfTrash = false
        await model.refresh()
        await #expect(throws: HistoryModelError.cantTakeOutOfTrash) {
            _ = try await model.restore(runID: run.id)
        }
        #expect(HistoryModelError.cantTakeOutOfTrash.localizedDescription
            == "Dustling can't take things out of the Trash without Full Disk Access.")
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func restoringCheckedItemsAcrossRunsPutsBackOnlyThose() async throws {
        let rig = try ModelRig()
        let a = rig.root.appending(path: "orig/a.txt")
        let b = rig.root.appending(path: "orig/b.txt")
        let c = rig.root.appending(path: "orig/c.txt")
        let runA = try trashedRun(rig, name: "a.txt", original: a.path, ago: 60)
        _ = try trashedRun(rig, name: "b.txt", original: b.path, ago: 120)
        _ = try trashedRun(rig, name: "c.txt", original: c.path, ago: 180)
        let completed = Counter()
        let model = HistoryModel(journal: rig.journal, onRunCompleted: { completed.bump() })
        await model.refresh()
        let chosen = model.allItems.filter { $0.path == a.path || $0.path == b.path }

        let outcomes = try await model.restore(items: chosen)

        #expect(outcomes.count == 2)
        #expect(outcomes.contains(.restored(a.path)) && outcomes.contains(.restored(b.path)))
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(!FileManager.default.fileExists(atPath: c.path))
        #expect(completed.value == 1)
        #expect(model.allItems.first { $0.runID == runA.id }?.entry.restored == true)
        #expect(model.lastRestore?.title == "Put back 2 items.")
    }

    @Test func bugReportReadsTheRunsLinesFromTheLogFile() async throws {
        let rig = try ModelRig()
        let logger = RunLogger(directory: rig.environment.logsDirectory)
        let run = RunRecord(
            startedAt: Date(), kind: .startupChange,
            entries: [JournalEntry(originalPath: rig.environment.home.appending(path: "x.plist").path(percentEncoded: false),
                                   bytes: 0, outcome: .skipped(reason: "disabled"))],
            restorable: false)
        try rig.journal.save(run)
        try logger.write(run)
        let model = HistoryModel(journal: rig.journal, logger: logger, home: rig.environment.home)
        await model.refresh()
        let text = await model.bugReport(for: run.id)
        #expect(text.hasPrefix(ISO8601DateFormatter().string(from: run.startedAt)))
        #expect(text.contains("skipped: disabled"))
        #expect(text.contains("~/x.plist"))
        #expect(model.logFile(for: run.id) == logger.file(for: run.startedAt))
    }

    #if DEBUG
    @Test func fixtureNeverTouchesTheDisk() async throws {
        let rig = try ModelRig()
        let model = HistoryModel(journal: rig.journal)
        let fake = RunRecord(
            startedAt: Date(), kind: .junkClean,
            entries: [JournalEntry(originalPath: "/nowhere/a", bytes: 1, outcome: .movedToTrash(trashedPath: "/nowhere/t/a"))],
            restorable: true)
        model.showFixture([fake])
        #expect(model.runs.map(\.id) == [fake.id])
        #expect(model.runs.first?.restorable == true)
        await model.refresh()
        #expect(model.runs.map(\.id) == [fake.id])
        await #expect(throws: HistoryModelError.fixture) {
            _ = try await model.restore(runID: fake.id)
        }
        #expect(try rig.journal.all().isEmpty)
    }
    #endif
}
