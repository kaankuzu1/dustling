import Foundation
import Testing
@testable import DustlingCore

struct RunJournalTests {
    private func journal(_ s: TestSandbox) -> RunJournal {
        RunJournal(directory: s.root.appending(path: "history", directoryHint: .isDirectory))
    }

    private func trashMover(_ s: TestSandbox) -> TrashMover {
        TrashMover(
            backend: DirectoryTrashBackend(directory: s.root.appending(path: "trash", directoryHint: .isDirectory)),
            protectedPaths: ProtectedPaths(environment: s.environment))
    }

    /// Trashes `url` and builds a one-entry run from the real outcome.
    private func trashedRun(_ s: TestSandbox, _ urls: [URL], date: Date = Date(timeIntervalSince1970: 1_000)) -> RunRecord {
        let mover = trashMover(s)
        let home = s.root.appending(path: "home")
        let entries = urls.map { url in
            JournalEntry(
                originalPath: url.path(percentEncoded: false), bytes: 1,
                outcome: mover.moveToTrash(url, allowedRoots: [home]), restored: false)
        }
        return RunRecord(id: UUID(), startedAt: date, kind: .junkClean, entries: entries, restorable: true)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let s = try TestSandbox()
        let j = journal(s)
        let older = RunRecord(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 1_000), kind: .junkClean,
            entries: [JournalEntry(originalPath: "/x", bytes: 5, outcome: .failed(reason: "no"), restored: false)],
            restorable: false)
        let newer = RunRecord(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 2_000), kind: .uninstall(appName: "Foo"),
            entries: [JournalEntry(originalPath: "/y", bytes: 7, outcome: .movedToTrash(trashedPath: "/t/y"), restored: false)],
            restorable: true)
        try j.save(older)
        try j.save(newer)
        #expect(try j.all() == [newer, older])
        #expect(newer.bytesMovedToTrash == 7)
        #expect(older.failedCount == 1)
    }

    @Test func restoreMovesBackAndMarksRestored() throws {
        let s = try TestSandbox()
        let file = try s.file("home/Library/Caches/a.log", bytes: 3)
        let run = trashedRun(s, [file])
        let j = journal(s)
        try j.save(run)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let out = try j.restore(runID: run.id)
        #expect(out == [.restored(file.path(percentEncoded: false))])
        #expect(FileManager.default.fileExists(atPath: file.path))
        let saved = try #require(try j.all().first)
        #expect(saved.entries[0].restored)
        #expect(!saved.restorable)
        // Restoring again ignores already-restored entries.
        #expect(try j.restore(runID: run.id) == [])
    }

    @Test func restoreDoesNotOverwriteReoccupiedPath() throws {
        let s = try TestSandbox()
        let file = try s.file("home/Library/Caches/a.log", bytes: 3)
        let run = trashedRun(s, [file])
        let j = journal(s)
        try j.save(run)
        try Data("new".utf8).write(to: file)
        let out = try j.restore(runID: run.id)
        #expect(out == [.conflict(file.path(percentEncoded: false))])
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        guard case .movedToTrash(let t) = run.entries[0].outcome else { Issue.record("not trashed"); return }
        #expect(FileManager.default.fileExists(atPath: t))
        #expect(try j.all()[0].restorable)
    }

    @Test func danglingSymlinkCountsAsOccupied() throws {
        let s = try TestSandbox()
        let file = try s.file("home/Library/Caches/a.log")
        let run = trashedRun(s, [file])
        let j = journal(s)
        try j.save(run)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/nonexistent-dustling")
        #expect(try j.restore(runID: run.id) == [.conflict(file.path(percentEncoded: false))])
    }

    @Test func journalRecordsActualTrashPathsOnCollision() throws {
        let s = try TestSandbox()
        let a = try s.file("home/a/Caches/one.txt", bytes: 1).deletingLastPathComponent()
        let b = try s.file("home/b/Caches/two.txt", bytes: 2).deletingLastPathComponent()
        let run = trashedRun(s, [a, b])
        let trashed = run.entries.compactMap { e -> String? in
            if case .movedToTrash(let p) = e.outcome { return p } else { return nil }
        }
        #expect(trashed.count == 2)
        #expect(trashed[0].hasSuffix("/Caches"))
        #expect(trashed[1].hasSuffix("/Caches 2"))
        let j = journal(s)
        try j.save(run)
        let out = try j.restore(runID: run.id)
        #expect(out.count == 2)
        #expect(FileManager.default.fileExists(atPath: a.appending(path: "one.txt").path))
        #expect(FileManager.default.fileExists(atPath: b.appending(path: "two.txt").path))
        #expect(!FileManager.default.fileExists(atPath: a.appending(path: "two.txt").path))
        #expect(!FileManager.default.fileExists(atPath: b.appending(path: "one.txt").path))
    }

    @Test func missingTrashedItemIsReported() throws {
        let s = try TestSandbox()
        let file = try s.file("home/Library/Caches/a.log")
        let run = trashedRun(s, [file])
        let j = journal(s)
        try j.save(run)
        guard case .movedToTrash(let t) = run.entries[0].outcome else { Issue.record("not trashed"); return }
        try FileManager.default.removeItem(atPath: t)
        #expect(try j.restore(runID: run.id) == [.missingFromTrash(file.path(percentEncoded: false))])
        #expect(!(try j.all()[0].entries[0].restored))
    }

    @Test func refreshMarksEmptiedRunsNotRestorable() throws {
        let s = try TestSandbox()
        let f1 = try s.file("home/Library/Caches/a.log")
        let f2 = try s.file("home/Library/Caches/b.log")
        let emptied = trashedRun(s, [f1], date: Date(timeIntervalSince1970: 1_000))
        let intact = trashedRun(s, [f2], date: Date(timeIntervalSince1970: 2_000))
        let j = journal(s)
        try j.save(emptied)
        try j.save(intact)
        guard case .movedToTrash(let t) = emptied.entries[0].outcome else { Issue.record("not trashed"); return }
        try FileManager.default.removeItem(atPath: t)
        try j.refreshRestorability()
        let all = try j.all()
        #expect(all[0].id == intact.id && all[0].restorable)
        #expect(all[1].id == emptied.id && !all[1].restorable)
    }

    @Test func unknownRunThrows() throws {
        let s = try TestSandbox()
        let id = UUID()
        #expect(throws: RunJournalError.runNotFound(id)) { try journal(s).restore(runID: id) }
    }

    @Test func partialRestoreByPaths() throws {
        let s = try TestSandbox()
        let f1 = try s.file("home/Library/Caches/a.log")
        let f2 = try s.file("home/Library/Caches/b.log")
        let run = trashedRun(s, [f1, f2])
        let j = journal(s)
        try j.save(run)
        let out = try j.restore(runID: run.id, paths: [f1.path(percentEncoded: false)])
        #expect(out == [.restored(f1.path(percentEncoded: false))])
        #expect(!FileManager.default.fileExists(atPath: f2.path))
        #expect(try j.all()[0].restorable)
    }

    @Test func corruptRecordIsReportedNotFatal() throws {
        let s = try TestSandbox()
        let j = journal(s)
        let good = RunRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_000), kind: .emptyTrash, entries: [], restorable: false)
        try j.save(good)
        let dir = s.root.appending(path: "history")
        let bad = dir.appending(path: "\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: bad)
        #expect(try j.all() == [good])
        #expect(j.unreadableRecords().map(\.lastPathComponent) == [bad.lastPathComponent])
    }
}
