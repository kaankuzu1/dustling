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

    @Test func newestIsTheRunThatStartedLastEvenIfAnOlderOneWasSavedLater() throws {
        let s = try TestSandbox()
        let j = journal(s)
        #expect(try j.newest() == nil)
        let older = RunRecord(startedAt: Date().addingTimeInterval(-300), kind: .junkClean, entries: [], restorable: false)
        let newer = RunRecord(startedAt: Date().addingTimeInterval(-60), kind: .emptyTrash, entries: [], restorable: false)
        try j.save(older)
        try j.save(newer)
        var resaved = older
        resaved.restorable = true
        try j.save(resaved)   // written last, started first
        try Data("not json".utf8).write(to: s.root.appending(path: "history/broken.json"))
        #expect(try j.newest()?.id == newer.id)
    }

    /// One run per app in a multi-app uninstall starts within the same second; they keep their order.
    @Test func runsInTheSameSecondKeepTheirOrder() throws {
        let s = try TestSandbox()
        let j = journal(s)
        let start = Date(timeIntervalSince1970: 1_700_000_000.1)
        let runs = (0..<6).map { i in
            RunRecord(startedAt: start.addingTimeInterval(Double(i) * 0.05), kind: .uninstall(appName: "App \(i)"),
                      entries: [], restorable: true)
        }
        for run in runs.shuffled() { try j.save(run) }
        #expect(try j.all().map(\.id) == runs.reversed().map(\.id))
        #expect(try j.newest()?.id == runs.last?.id)
    }

    /// History files written by 0.1.0 store whole seconds; they still read.
    @Test func readsWholeSecondDatesFromOlderVersions() throws {
        let s = try TestSandbox()
        let j = journal(s)
        let run = RunRecord(startedAt: Date(timeIntervalSince1970: 1_000), kind: .junkClean, entries: [], restorable: false)
        try j.save(run)
        let file = s.root.appending(path: "history/\(run.id.uuidString).json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("1970-01-01T00:16:40.000Z"))
        try text.replacingOccurrences(of: "1970-01-01T00:16:40.000Z", with: "1970-01-01T00:16:40Z")
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(try j.all().first?.startedAt == run.startedAt)
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
        // Restoring again is refused: nothing in the run can be put back.
        #expect(throws: RunJournalError.notRestorable(run.id)) { try j.restore(runID: run.id) }
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
        let other = try s.file("home/Library/Caches/b.log")
        let run = trashedRun(s, [file, other])
        let j = journal(s)
        try j.save(run)
        guard case .movedToTrash(let t) = run.entries[0].outcome else { Issue.record("not trashed"); return }
        try FileManager.default.removeItem(atPath: t)
        #expect(try j.restore(runID: run.id)
            == [.missingFromTrash(file.path(percentEncoded: false)), .restored(other.path(percentEncoded: false))])
        #expect(!(try j.all()[0].entries[0].restored))
    }

    @Test func runWithNothingLeftInTheTrashIsRefused() throws {
        let s = try TestSandbox()
        let file = try s.file("home/Library/Caches/a.log")
        let run = trashedRun(s, [file])
        let j = journal(s)
        try j.save(run)
        guard case .movedToTrash(let t) = run.entries[0].outcome else { Issue.record("not trashed"); return }
        try FileManager.default.removeItem(atPath: t)
        #expect(throws: RunJournalError.notRestorable(run.id)) { try j.restore(runID: run.id) }
        #expect(!(try j.all()[0].restorable))
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

    @Test func failedMoveIsReportedAndOthersStillRestore() throws {
        let s = try TestSandbox()
        let bad = try s.file("home/blk/a.log")
        let good = try s.file("home/ok/b.log")
        let run = trashedRun(s, [bad, good])
        let j = journal(s)
        try j.save(run)
        // Replace the parent folder with a regular file so recreating it fails.
        try FileManager.default.removeItem(at: s.root.appending(path: "home/blk"))
        try Data("x".utf8).write(to: s.root.appending(path: "home/blk"))
        let out = try j.restore(runID: run.id)
        #expect(out.count == 2)
        guard case .failed(let p, let reason) = out[0] else { Issue.record("expected failed, got \(out[0])"); return }
        #expect(p == bad.path(percentEncoded: false))
        #expect(!reason.isEmpty)
        #expect(out[1] == .restored(good.path(percentEncoded: false)))
        let saved = try #require(try j.all().first)
        #expect(!saved.entries[0].restored)
        #expect(saved.entries[1].restored)
        #expect(saved.restorable)
    }

    @Test func permissionRefusalOutOfTheTrashNamesTheTrashAndFullDiskAccess() {
        let denied = CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])
        #expect(RunJournal.restoreFailureReason(denied, trashedPath: "/Users/k/.Trash/CoreSimulator", home: "/Users/k")
            == "Dustling can't take it out of the Trash (~/.Trash) without Full Disk Access")
        #expect(RunJournal.restoreFailureReason(POSIXError(.EACCES), trashedPath: "/Volumes/S/.Trashes/501/x", home: "/Users/k")
            == "Dustling can't take it out of the Trash (/Volumes/S/.Trashes/501) without Full Disk Access")
        #expect(RunJournal.restoreFailureReason(
            denied, trashedPath: "/Users/k/.Trash/x", destinationWritable: false, home: "/Users/k") == denied.localizedDescription)
        let other = POSIXError(.EIO)
        #expect(RunJournal.restoreFailureReason(other, trashedPath: "/Users/k/.Trash/x", home: "/Users/k")
            == other.localizedDescription)
    }

    @Test func unreadableHistoryDirectoryThrows() throws {
        let s = try TestSandbox()
        let j = journal(s)
        try j.save(RunRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_000), kind: .emptyTrash, entries: [], restorable: false))
        let dir = s.root.appending(path: "history")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        #expect(throws: RunJournalError.self) { try j.all() }
    }

    @Test func missingHistoryDirectoryIsEmpty() throws {
        let s = try TestSandbox()
        #expect(try journal(s).all().isEmpty)
    }

    @Test func saveFailureStopsAndCarriesOutcomes() throws {
        let s = try TestSandbox()
        let f1 = try s.file("home/Library/Caches/a.log")
        let f2 = try s.file("home/Library/Caches/b.log")
        let run = trashedRun(s, [f1, f2])
        let j = journal(s)
        try j.save(run)
        let dir = s.root.appending(path: "history")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        do {
            _ = try j.restore(runID: run.id)
            Issue.record("expected saveFailed")
        } catch RunJournalError.saveFailed(let outcomes, _) {
            #expect(outcomes == [.restored(f1.path(percentEncoded: false))])
            #expect(FileManager.default.fileExists(atPath: f1.path))
            #expect(!FileManager.default.fileExists(atPath: f2.path))
        }
    }
    // MARK: - Trashed identity (Important #4)

    private func runner(_ s: TestSandbox, trash: URL) -> CleanupRunner {
        CleanupRunner(
            mover: TrashMover(backend: DirectoryTrashBackend(directory: trash),
                              protectedPaths: ProtectedPaths(environment: s.environment)),
            journal: RunJournal(directory: s.environment.historyDirectory),
            logger: RunLogger(directory: s.environment.logsDirectory), sizer: DirectorySizer())
    }

    private func trashedPath(_ entry: JournalEntry) -> String? {
        if case .movedToTrash(let p) = entry.outcome { return p }
        return nil
    }

    @Test func restoringAnOldRunNeverMovesANewerItemWithTheSameTrashName() async throws {
        let s = try TestSandbox()
        let root = try s.directory("home/Library/Caches")
        let file = root.appending(path: "a.log")
        try Data("old".utf8).write(to: file)
        let j = RunJournal(directory: s.environment.historyDirectory)
        let clean = runner(s, trash: s.environment.userTrash)

        let first = await clean.run([file], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        let inspector = TrashInspector(
            environment: s.environment, journal: j, logger: RunLogger(directory: s.environment.logsDirectory),
            sizer: DirectorySizer())
        _ = inspector.emptyTrash()
        try Data("new".utf8).write(to: file)
        let second = await clean.run([file], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        let reused = try #require(trashedPath(first.entries[0]))
        #expect(trashedPath(second.entries[0]) == reused)   // the Trash reused the name

        #expect(throws: RunJournalError.notRestorable(first.id)) { try j.restore(runID: first.id) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: URL(filePath: reused), encoding: .utf8) == "new")
        try j.refreshRestorability()
        let old = try #require(try j.all().first { $0.id == first.id })
        #expect(old.entries[0].gone && !old.restorable)

        #expect(try j.restore(runID: second.id) == [.restored(file.path(percentEncoded: false))])
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    }

    @Test func replacedTrashItemIsMissingAndPermanentlyGone() async throws {
        let s = try TestSandbox()
        let root = try s.directory("home/Library/Caches")
        let a = try s.file("home/Library/Caches/a.log")
        let b = try s.file("home/Library/Caches/b.log")
        let j = RunJournal(directory: s.environment.historyDirectory)
        let run = await runner(s, trash: s.root.appending(path: "trash")).run(
            [a, b], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        let trashedA = try #require(trashedPath(run.entries[0]))
        try FileManager.default.removeItem(atPath: trashedA)
        try Data("impostor".utf8).write(to: URL(filePath: trashedA))

        #expect(try j.restore(runID: run.id)
            == [.missingFromTrash(a.path(percentEncoded: false)), .restored(b.path(percentEncoded: false))])
        #expect(try String(contentsOf: URL(filePath: trashedA), encoding: .utf8) == "impostor")
        #expect(!FileManager.default.fileExists(atPath: a.path))
        let saved = try #require(try j.all().first)
        #expect(saved.entries[0].gone && !saved.entries[0].restored)
        #expect(!saved.restorable)
    }

    @Test func refreshNeverRevivesAReplacedEntry() async throws {
        let s = try TestSandbox()
        let root = try s.directory("home/Library/Caches")
        let a = try s.file("home/Library/Caches/a.log")
        let j = RunJournal(directory: s.environment.historyDirectory)
        let run = await runner(s, trash: s.root.appending(path: "trash")).run(
            [a], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        let trashedA = try #require(trashedPath(run.entries[0]))
        try FileManager.default.removeItem(atPath: trashedA)
        try Data("impostor".utf8).write(to: URL(filePath: trashedA))
        try j.refreshRestorability()
        let saved = try #require(try j.all().first)
        #expect(saved.entries[0].gone && !saved.restorable)
        #expect(throws: RunJournalError.notRestorable(run.id)) { try j.restore(runID: run.id) }
        #expect(try String(contentsOf: URL(filePath: trashedA), encoding: .utf8) == "impostor")
    }

    @Test func recordsWithoutIdentityStillDecodeAndRestore() throws {
        let s = try TestSandbox()
        let file = try s.file("home/Library/Caches/a.log")
        let trashed = try s.file("trash/a.log")
        try FileManager.default.removeItem(at: file)
        let id = UUID()
        let json = """
            {"entries":[{"bytes":1,"originalPath":"\(file.path(percentEncoded: false))",
            "outcome":{"movedToTrash":{"trashedPath":"\(trashed.path(percentEncoded: false))"}},"restored":false}],
            "id":"\(id.uuidString)","kind":{"junkClean":{}},"restorable":true,"startedAt":"2026-11-07T10:00:00Z"}
            """
        let dir = s.root.appending(path: "history")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appending(path: "\(id.uuidString).json"))
        let j = journal(s)
        let run = try #require(try j.all().first)
        #expect(run.entries[0].trashedIdentity == nil && !run.entries[0].gone)
        #expect(try j.restore(runID: id) == [.restored(file.path(percentEncoded: false))])
    }
    @Test func refreshSaveFailureBeforeRestoreMovesNothing() async throws {
        let s = try TestSandbox()
        let root = try s.directory("home/Library/Caches")
        let a = try s.file("home/Library/Caches/a.log")
        let b = try s.file("home/Library/Caches/b.log")
        let j = RunJournal(directory: s.environment.historyDirectory)
        let run = await runner(s, trash: s.root.appending(path: "trash")).run(
            [a, b], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        let trashedA = try #require(trashedPath(run.entries[0]))
        try FileManager.default.removeItem(atPath: trashedA)
        try Data("impostor".utf8).write(to: URL(filePath: trashedA))   // refresh must mark a gone and save
        let dir = s.environment.historyDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        do {
            _ = try j.restore(runID: run.id)
            Issue.record("expected saveFailed")
        } catch RunJournalError.saveFailed(let outcomes, _) {
            #expect(outcomes.isEmpty)   // the CLI must not claim anything was restored
            #expect(!FileManager.default.fileExists(atPath: b.path))
        }
    }
}

