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

    // MARK: - Put back into system folders with the password

    /// A run that moved `items` (trashed path → original path) to the Trash, with the identity each
    /// trashed item has now (`owner: false` drops the owner, as journals written before it had).
    private func trashedRecord(
        _ items: [(URL, URL)], owner: Bool = true, kind: RunKind = .uninstall(appName: "Foo")
    ) -> RunRecord {
        RunRecord(startedAt: Date(timeIntervalSince1970: 1_000), kind: kind, entries: items.map {
            var identity = TrashedIdentity.of(path: $0.0.path(percentEncoded: false))
            if !owner { identity?.owner = nil }
            return JournalEntry(originalPath: $0.1.path(percentEncoded: false), bytes: 1,
                                outcome: .movedToTrash(trashedPath: $0.0.path(percentEncoded: false)),
                                trashedIdentity: identity)
        }, restorable: true)
    }

    private func adminMover(_ shell: any AdminShell, _ s: TestSandbox) throws -> AdminMover {
        AdminMover(shell: shell, environment: s.environment, planning: try s.adminPlanning())
    }

    @Test func restoreUsesPasswordForSystemFolders() throws {
        // An uninstall put back: straight out of the Trash, straight into Applications, which the
        // user can't write (a standard account), and a leftover into the user's own caches.
        let s = try TestSandbox()
        let tools = s.root.appending(path: "Applications")
        let helper = try s.directory("home/.Trash/com.example.app")
        let mine = try s.file("home/.Trash/a.log", bytes: 2)
        try s.directory("home/Library/Caches")
        let original = tools.appending(path: "com.example.app")
        let myOriginal = s.root.appending(path: "home/Library/Caches/a.log")
        let run = trashedRecord([(helper, original), (mine, myOriginal)])
        let j = journal(s)
        try j.save(run)
        FolderMode.lock(tools)
        defer { FolderMode.unlock(tools) }
        // The script runs as the user: the folder opens again only after planning.
        let shell = UserShell(beforeRun: { FolderMode.unlock(tools) })
        let out = try j.restore(runID: run.id, admin: try adminMover(shell, s))
        #expect(out == [.restored(original.path(percentEncoded: false)), .restored(myOriginal.path(percentEncoded: false))])
        #expect(shell.calls.count == 1)
        #expect(shell.calls.first?.prompt == AdminMover.restorePrompt(count: 1))
        // The recorded item (owner included) is what the script must find in the Trash, and the
        // folder Put back checked is the one it must find there.
        let recorded = try #require(run.entries[0].trashedIdentity)
        #expect(shell.calls.first?.script.contains(" \(recorded.dev):\(recorded.ino):\(getuid()) ") == true)
        let folder = try #require(ItemIdentity.of(tools))
        #expect(shell.calls.first?.script.contains(" \(folder.stamp) 'com.example.app'\n") == true)
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        let saved = try #require(try j.all().first)
        #expect(saved.entries.allSatisfy { $0.restored })
        #expect(!saved.restorable)
    }

    @Test func restoreUsesPasswordForAFolderTheUserCantWrite() throws {
        // Moving a folder to another folder changes its "..": without write access to the folder
        // itself (an app root installed), only the password can put it back.
        let s = try TestSandbox()
        let apps = try s.directory("home/Applications")
        let app = try s.file("home/.Trash/Foo.app/Contents/Info.plist", bytes: 3)
            .deletingLastPathComponent().deletingLastPathComponent()
        let original = apps.appending(path: "Foo.app")
        let run = trashedRecord([(app, original)])
        let j = journal(s)
        try j.save(run)
        FolderMode.lock(app)
        defer { FolderMode.unlock(app); FolderMode.unlock(original) }
        let shell = UserShell(beforeRun: { FolderMode.unlock(app) })
        #expect(try j.restore(runID: run.id, admin: try adminMover(shell, s)) == [.restored(original.path(percentEncoded: false))])
        #expect(shell.calls.count == 1)
        #expect(FileManager.default.fileExists(atPath: original.appending(path: "Contents/Info.plist").path))
    }

    @Test func restoreKeepsTheItemInTheTrashWhenPasswordCancelled() throws {
        let s = try TestSandbox()
        let tools = s.root.appending(path: "Applications")
        let helper = try s.file("home/.Trash/Tool.app", bytes: 4)
        let original = tools.appending(path: "Tool.app")
        let run = trashedRecord([(helper, original)])
        let j = journal(s)
        try j.save(run)
        FolderMode.lock(tools)
        defer { FolderMode.unlock(tools) }
        let shell = CannedShell(.cancelled)
        let out = try j.restore(runID: run.id, admin: try adminMover(shell, s))
        #expect(out == [.failed(original.path(percentEncoded: false), reason: "Put back needs your password")])
        #expect(RunJournal.putBackNeedsPasswordReason == "Put back needs your password")
        #expect(shell.calls.count == 1)
        #expect(FileManager.default.fileExists(atPath: helper.path(percentEncoded: false)))
        let saved = try #require(try j.all().first)
        #expect(!saved.entries[0].restored && saved.restorable)
    }

    @Test func restoreWithoutRecordedOwnerSaysUsePutBackInFinder() throws {
        let s = try TestSandbox()
        let tools = try s.directory("Library/PrivilegedHelperTools")
        let helper = try s.file("home/.Trash/com.example.helper", bytes: 4)
        let original = tools.appending(path: "com.example.helper")
        let run = trashedRecord([(helper, original)], owner: false)
        let j = journal(s)
        try j.save(run)
        FolderMode.lock(tools)
        defer { FolderMode.unlock(tools) }
        let shell = CannedShell(.finished(output: "R\t0\tok\n"))
        let out = try j.restore(runID: run.id, admin: try adminMover(shell, s))
        guard case .failed(let p, let reason) = out.first else { Issue.record("expected failed, got \(out)"); return }
        #expect(p == original.path(percentEncoded: false))
        #expect(reason.hasSuffix(" Use Put Back in Finder."))
        #expect(shell.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: helper.path(percentEncoded: false)))
    }

    @Test func restoreWithoutAdminNeverAsks() throws {
        let s = try TestSandbox()
        let tools = try s.directory("Library/PrivilegedHelperTools")
        let helper = try s.file("home/.Trash/com.example.helper", bytes: 4)
        let original = tools.appending(path: "com.example.helper")
        let run = trashedRecord([(helper, original)])
        let j = journal(s)
        try j.save(run)
        FolderMode.lock(tools)
        defer { FolderMode.unlock(tools) }
        let out = try j.restore(runID: run.id)
        guard case .failed(_, let reason) = out.first else { Issue.record("expected failed, got \(out)"); return }
        #expect(!reason.contains("Finder") && !reason.contains("password"))
        #expect(FileManager.default.fileExists(atPath: helper.path(percentEncoded: false)))
    }

    @Test func trashedIdentityRecordsTheOwnerAndOlderJournalsStillDecode() throws {
        let s = try TestSandbox()
        let file = try s.file("home/.Trash/a.log")
        #expect(TrashedIdentity.of(path: file.path(percentEncoded: false))?.owner == getuid())
        let json = #"{"dev":1,"ino":2,"birthtime":3.5}"#
        let old = try JSONDecoder().decode(TrashedIdentity.self, from: Data(json.utf8))
        #expect(old == TrashedIdentity(dev: 1, ino: 2, birthtime: 3.5))
        #expect(old.owner == nil)
        let encoded = try JSONEncoder().encode(TrashedIdentity(dev: 1, ino: 2, birthtime: 3.5, owner: 0))
        #expect(try JSONDecoder().decode(TrashedIdentity.self, from: encoded).owner == 0)
    }

    @Test func restoreNeverAsksForAFolderThatIsALink() throws {
        // Planning refuses a destination folder that is a link (it opens with O_NOFOLLOW), so the
        // password would only be asked for to be refused: the move's own failure stands.
        let s = try TestSandbox()
        let real = try s.directory("Library/Tools-real")
        let tools = s.root.appending(path: "Library/PrivilegedHelperTools")
        try FileManager.default.createSymbolicLink(at: tools, withDestinationURL: real)
        let helper = try s.file("home/.Trash/com.example.helper", bytes: 4)
        let original = tools.appending(path: "com.example.helper")
        let run = trashedRecord([(helper, original)])
        let j = journal(s)
        try j.save(run)
        FolderMode.lock(real)
        defer { FolderMode.unlock(real) }
        let shell = CannedShell(.finished(output: "R\t0\tok\n"))
        let out = try j.restore(runID: run.id, admin: try adminMover(shell, s))
        guard case .failed(_, let reason) = out.first else { Issue.record("expected failed, got \(out)"); return }
        #expect(!reason.contains("Finder") && !reason.contains("password"))
        #expect(shell.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: helper.path(percentEncoded: false)))
    }

    // MARK: - Put back with the password trusts nothing in a History file

    /// A run another program running as the user wrote into History: `trashed` back to `original`,
    /// with `lock` locked so the normal move fails for lack of permission. The shell records every
    /// call and runs nothing.
    private func forgedPutBack(
        _ s: TestSandbox, trashed: URL, original: URL, kind: RunKind, lock: [URL]
    ) throws -> (out: [RestoreOutcome], shell: CannedShell) {
        let run = trashedRecord([(trashed, original)], kind: kind)
        let j = journal(s)
        try j.save(run)
        for folder in lock { FolderMode.lock(folder) }
        defer { for folder in lock { FolderMode.unlock(folder) } }
        let shell = CannedShell(.finished(output: "R\t0\tok\n"))
        let out = try j.restore(runID: run.id, admin: try adminMover(shell, s))
        return (out, shell)
    }

    /// The entry failed with the move's own reason and points to Finder's Put Back.
    private func expectPutBackInFinder(_ out: [RestoreOutcome], _ original: URL) {
        guard out.count == 1, case .failed(let p, let reason) = out[0] else {
            Issue.record("expected one failed entry, got \(out)")
            return
        }
        #expect(p == original.path(percentEncoded: false))
        #expect(reason.hasSuffix(" Use Put Back in Finder."))
    }

    @Test func aForgedSourceOutsideTheTrashNeverReachesTheShell() throws {
        let s = try TestSandbox()
        let caches = try s.directory("Library/Caches")
        try s.directory("home/.Trash")
        // Somewhere else, or in a folder inside the Trash (not directly in it).
        let sources = [try s.file("home/Downloads/zshenv", bytes: 3), try s.file("home/.Trash/inner/zshenv", bytes: 3)]
        for (index, source) in sources.enumerated() {
            let original = caches.appending(path: "zshenv \(index)")
            let (out, shell) = try forgedPutBack(s, trashed: source, original: original, kind: .junkClean, lock: [caches])
            expectPutBackInFinder(out, original)
            #expect(shell.calls.isEmpty)
            #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        }
    }

    @Test func aForgedDestinationOutsideTheDeclaredFoldersNeverReachesTheShell() throws {
        let s = try TestSandbox()
        let etc = try s.directory("private/etc")
        let daemons = try s.directory("Library/LaunchDaemons")
        let system = try s.directory("Library/Caches")
        let caches = try s.directory("home/Library/Caches")
        let deeper = try s.directory("home/Library/Caches/deeper")
        let apps = s.root.appending(path: "Applications")
        let bundle = try s.directory("Applications/Tool.app/Contents")
        let uninstall = RunKind.uninstall(appName: "Foo")
        let cases: [(original: URL, kind: RunKind, lock: [URL])] = [
            // Root's shell startup file: no run moves anything from there.
            (etc.appending(path: "zshenv"), uninstall, [etc]),
            (etc.appending(path: "zshenv"), .junkClean, [etc]),
            // A folder an uninstall uses, in a run of another kind.
            (daemons.appending(path: "com.evil.plist"), .junkClean, [daemons]),
            // System caches and logs: Dustling never cleans them, so nothing goes back there either.
            (system.appending(path: "com.evil"), .junkClean, [system]),
            // Inside a declared folder, not directly in it.
            (deeper.appending(path: "evil"), .junkClean, [deeper]),
            // An "app" inside another app, and something that isn't an app, in Applications.
            (bundle.appending(path: "Helper.app"), uninstall, [bundle]),
            (apps.appending(path: "evil"), uninstall, [apps]),
            // Runs that never use the password.
            (caches.appending(path: "evil"), .startupChange, [caches]),
            (caches.appending(path: "evil"), .emptyTrash, [caches]),
        ]
        for (index, forged) in cases.enumerated() {
            let trashed = try s.file("home/.Trash/evil \(index)", bytes: 3)
            let (out, shell) = try forgedPutBack(
                s, trashed: trashed, original: forged.original, kind: forged.kind, lock: forged.lock)
            expectPutBackInFinder(out, forged.original)
            #expect(shell.calls.isEmpty, "\(forged.original.path(percentEncoded: false)) \(forged.kind)")
            #expect(FileManager.default.fileExists(atPath: trashed.path(percentEncoded: false)))
        }
    }

    @Test func aLinkAboveTheFolderNeverReachesTheShell() throws {
        // ~/Library swapped for a link to the system Library: ~/Library/LaunchAgents, a folder an
        // uninstall uses, now leads into the system's LaunchAgents.
        let s = try TestSandbox()
        let system = try s.directory("Library/LaunchAgents")
        let library = s.root.appending(path: "home/Library")
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: s.root.appending(path: "Library"))
        let original = library.appending(path: "LaunchAgents/com.evil.plist")
        let trashed = try s.file("home/.Trash/com.evil.plist", bytes: 3)
        let (out, shell) = try forgedPutBack(
            s, trashed: trashed, original: original, kind: .uninstall(appName: "Foo"), lock: [system])
        expectPutBackInFinder(out, original)
        #expect(shell.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: system.appending(path: "com.evil.plist").path(percentEncoded: false)))
    }

    @Test func onlyRootsItemsGoBackIntoTheSystemLaunchAndHelperFolders() throws {
        // launchd runs a helper there as root whoever owns it: the user's own file never goes there
        // with the password (a test can't make root's items, so only the refusal is shown).
        let s = try TestSandbox()
        for name in ["LaunchDaemons", "LaunchAgents", "PrivilegedHelperTools"] {
            let folder = try s.directory("Library/\(name)")
            let trashed = try s.file("home/.Trash/com.example.\(name)", bytes: 3)
            let original = folder.appending(path: "com.example.\(name)")
            let (out, shell) = try forgedPutBack(
                s, trashed: trashed, original: original, kind: .uninstall(appName: "Foo"), lock: [folder])
            expectPutBackInFinder(out, original)
            #expect(shell.calls.isEmpty)
        }
    }

    @Test func restoreUsesPasswordForAnAppInAFolderInApplications() throws {
        let s = try TestSandbox()
        let vendor = try s.directory("Applications/Vendor")
        let app = try s.file("home/.Trash/Foo.app/Contents/Info.plist", bytes: 3)
            .deletingLastPathComponent().deletingLastPathComponent()
        let original = vendor.appending(path: "Foo.app")
        let run = trashedRecord([(app, original)])
        let j = journal(s)
        try j.save(run)
        FolderMode.lock(vendor)
        defer { FolderMode.unlock(vendor) }
        let shell = UserShell(beforeRun: { FolderMode.unlock(vendor) })
        #expect(try j.restore(runID: run.id, admin: try adminMover(shell, s)) == [.restored(original.path(percentEncoded: false))])
        #expect(shell.calls.count == 1)
        #expect(FileManager.default.fileExists(atPath: original.appending(path: "Contents/Info.plist").path(percentEncoded: false)))
    }

    @Test func restoreWithThePasswordWorksWithResolvedPaths() throws {
        // A listing can hand back /private/var/... for the sandbox's /var/...: the run's paths are
        // then not written the way the environment names its folders, and Put back still works.
        let s = try TestSandbox()
        let apps = s.root.appending(path: "Applications")
        let app = try s.file("home/.Trash/Foo.app/Contents/Info.plist", bytes: 3)
            .deletingLastPathComponent().deletingLastPathComponent()
        let real = try #require(ProtectedPaths.realpathString(AdminPath.trimmingTrailingSlashes(s.root.path(percentEncoded: false))))
        try #require(real != AdminPath.trimmingTrailingSlashes(s.root.path(percentEncoded: false)))
        let resolved = { (url: URL) in
            URL(fileURLWithPath: real + String(AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false))
                .dropFirst(AdminPath.trimmingTrailingSlashes(s.root.path(percentEncoded: false)).count)))
        }
        let original = resolved(apps.appending(path: "Foo.app"))
        let run = trashedRecord([(resolved(app), original)])
        let j = journal(s)
        try j.save(run)
        FolderMode.lock(apps)
        defer { FolderMode.unlock(apps) }
        let shell = UserShell(beforeRun: { FolderMode.unlock(apps) })
        #expect(try j.restore(runID: run.id, admin: try adminMover(shell, s)) == [.restored(original.path(percentEncoded: false))])
        #expect(shell.calls.count == 1)
        #expect(FileManager.default.fileExists(atPath: apps.appending(path: "Foo.app/Contents/Info.plist").path(percentEncoded: false)))
    }

    @Test func theFolderIsFoundWithoutFollowingLinks() throws {
        let s = try TestSandbox()
        let caches = try s.directory("home/Library/Caches")
        let system = try s.directory("Library/Caches")
        let environment = s.environment
        func path(_ url: URL) -> String { AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false)) }
        #expect(PasswordPutBack.folderWithoutLinks(path(caches), environment: environment) == ItemIdentity.of(caches))
        #expect(PasswordPutBack.folderWithoutLinks(path(system), environment: environment) == ItemIdentity.of(system))
        // Outside home, the system library and the application folders: nothing.
        let elsewhere = try s.directory("private/etc")
        #expect(PasswordPutBack.folderWithoutLinks(path(elsewhere), environment: environment) == nil)
        // A link anywhere below home.
        let real = try s.directory("home/Real")
        try s.directory("home/Real/Caches")
        try FileManager.default.createSymbolicLink(
            at: s.root.appending(path: "home/Linked"), withDestinationURL: real)
        #expect(PasswordPutBack.folderWithoutLinks(path(s.root.appending(path: "home/Linked/Caches")), environment: environment) == nil)
        #expect(PasswordPutBack.folderWithoutLinks(path(s.root.appending(path: "home/Linked")), environment: environment) == nil)
    }
}
