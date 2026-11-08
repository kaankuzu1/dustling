import Foundation
import Testing
@testable import DustlingCore

struct CleanupRunnerTests {
    struct Boom: LocalizedError {
        var errorDescription: String? { "disk exploded" }
    }
    /// Fails for one file name, otherwise behaves like the directory backend.
    struct SelectiveBackend: TrashBackend {
        let inner: DirectoryTrashBackend
        let failingName: String
        func trash(_ url: URL) throws -> URL {
            if url.lastPathComponent == failingName { throw Boom() }
            return try inner.trash(url)
        }
    }

    private func makeRunner(
        _ sandbox: TestSandbox, failing: String? = nil, logsDirectory: URL? = nil
    ) -> CleanupRunner {
        let direct = DirectoryTrashBackend(directory: sandbox.root.appending(path: "trash", directoryHint: .isDirectory))
        let backend: TrashBackend = failing.map { SelectiveBackend(inner: direct, failingName: $0) } ?? direct
        return CleanupRunner(
            mover: TrashMover(backend: backend, protectedPaths: ProtectedPaths(environment: sandbox.environment)),
            journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: logsDirectory ?? sandbox.environment.logsDirectory),
            sizer: DirectorySizer())
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(URL, DeletionOutcome)] = []
        func add(_ url: URL, _ outcome: DeletionOutcome) { lock.lock(); items.append((url, outcome)); lock.unlock() }
        var all: [(URL, DeletionOutcome)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func logText(_ sandbox: TestSandbox) throws -> String {
        let dir = sandbox.environment.logsDirectory
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        return try String(contentsOf: files[0], encoding: .utf8)
    }

    @Test func everyItemGetsAnOutcomeAndOnItemFires() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let a = try sandbox.file("home/Library/Caches/a.log", bytes: 10)
        let b = try sandbox.file("home/Library/Caches/b.log", bytes: 20)
        let protected = try sandbox.file("home/Documents/x.txt", bytes: 5)
        let sizeA = DirectorySizer().measure(a).bytes   // sizer reports allocated size, not logical
        let sizeB = DirectorySizer().measure(b).bytes
        let seen = Collector()
        let record = await makeRunner(sandbox).run(
            [a, protected, b], kind: .junkClean, allowedRoots: [root, sandbox.root.appending(path: "home")]
        ) { url, outcome in seen.add(url, outcome) }
        #expect(record.entries.count == 3)
        #expect(seen.all.map(\.0) == [a, protected, b])
        #expect(record.entries[0].bytes == sizeA)
        #expect(record.entries[1].outcome == .skipped(reason: "protected location"))
        #expect(record.skippedCount == 1)
        #expect(record.bytesMovedToTrash == sizeA + sizeB)
        #expect(record.restorable)
    }

    @Test func totalsComeFromActualOutcomes() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let ok = try sandbox.file("home/Library/Caches/ok.log", bytes: 100)
        let bad = try sandbox.file("home/Library/Caches/bad.log", bytes: 900)
        let okSize = DirectorySizer().measure(ok).bytes
        let badSize = DirectorySizer().measure(bad).bytes
        let record = await makeRunner(sandbox, failing: "bad.log").run(
            [ok, bad], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        #expect(record.bytesMovedToTrash == okSize)
        #expect(record.failedCount == 1)
        #expect(record.entries[1].bytes == badSize)
        let text = try logText(sandbox)
        let expectedBytes = ByteCountFormatter.string(fromByteCount: Int64(okSize), countStyle: .file)
        #expect(text.contains("  total: moved \(expectedBytes) to Trash, 1 failed, 0 need admin, 0 skipped"))
    }

    @Test func runIsJournaledAndLogged() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log", bytes: 10)
        let record = await makeRunner(sandbox).run([file], kind: .uninstall(appName: "Foo"), allowedRoots: [root]) { _, _ in }
        let saved = try RunJournal(directory: sandbox.environment.historyDirectory).all()
        #expect(saved.map(\.id) == [record.id])
        #expect(saved.first?.entries == record.entries)
        let text = try logText(sandbox)
        #expect(text.contains("run=\(record.id.uuidString)"))
        #expect(text.contains("moved to Trash"))
        #expect(text.contains(file.path(percentEncoded: false)))
        #expect(text.contains(" -> "))
    }

    @Test func logFileNameUsesLocalDateAndAppends() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let runner = makeRunner(sandbox)
        let one = try sandbox.file("home/Library/Caches/1.log")
        let two = try sandbox.file("home/Library/Caches/2.log")
        _ = await runner.run([one], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        _ = await runner.run([two], kind: .emptyTrash, allowedRoots: [root]) { _, _ in }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        let name = "dustling-\(f.string(from: Date())).log"
        let text = try String(contentsOf: sandbox.environment.logsDirectory.appending(path: name), encoding: .utf8)
        #expect(text.components(separatedBy: "run=").count == 3)
        // The app's View log opens the same file.
        let logger = RunLogger(directory: sandbox.environment.logsDirectory)
        #expect(logger.file(for: Date()).lastPathComponent == name)
    }

    @Test func logFailureIsRecordedNotSwallowed() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log", bytes: 10)
        // A regular file where the logs directory should be makes directory creation fail.
        let blocker = try sandbox.file("blocker")
        let record = await makeRunner(sandbox, logsDirectory: blocker.appending(path: "logs")).run(
            [file], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        let entry = try #require(record.entries.first { $0.originalPath == "<log>" })
        guard case .failed = entry.outcome else { Issue.record("expected failed"); return }
        #expect(entry.bytes == 0)
        let saved = try #require(try RunJournal(directory: sandbox.environment.historyDirectory).all().first)
        #expect(saved.entries.contains { $0.originalPath == "<log>" })
    }

    @Test func journalFailureIsRecordedAndLogged() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log", bytes: 10)
        // Block the History directory with a regular file.
        try FileManager.default.createDirectory(
            at: sandbox.environment.historyDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: sandbox.environment.historyDirectory)
        let record = await makeRunner(sandbox).run([file], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        #expect(record.entries.contains { $0.originalPath == "<history>" })
        #expect(try logText(sandbox).contains("<history>"))
    }

    @Test func extraEntriesAreAppendedAfterOwnEntries() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log", bytes: 10)
        let extra = JournalEntry(originalPath: "/Library/LaunchDaemons/x.plist", bytes: 0, outcome: .needsAdmin)
        let record = await makeRunner(sandbox).run(
            [file], kind: .uninstall(appName: "Foo"), allowedRoots: [root], extraEntries: [extra]
        ) { _, _ in }
        #expect(record.entries.count == 2)
        #expect(record.entries[1] == extra)
        #expect(record.needsAdminCount == 1)
        #expect(try RunJournal(directory: sandbox.environment.historyDirectory).all().first?.entries.last == extra)
        #expect(try logText(sandbox).contains("/Library/LaunchDaemons/x.plist"))
    }

    @Test func notRestorableWhenNothingWasTrashed() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let record = await makeRunner(sandbox).run(
            [root.appending(path: "gone")], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        #expect(!record.restorable)
    }
    @Test func trashedIdentityIsCapturedAfterTheMove() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log")
        let gone = root.appending(path: "gone")
        let record = await makeRunner(sandbox).run([file, gone], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        guard case .movedToTrash(let trashed) = record.entries[0].outcome else { Issue.record("not trashed"); return }
        let identity = try #require(record.entries[0].trashedIdentity)
        #expect(identity == TrashedIdentity.of(path: trashed))
        #expect(record.entries[1].trashedIdentity == nil)
        let saved = try #require(try RunJournal(directory: sandbox.environment.historyDirectory).all().first)
        #expect(saved.entries[0].trashedIdentity == identity)
    }

    // MARK: incremental journaling

    /// Cancels the run's task (as Stop does) once `cancelAfter` items have been trashed.
    final class CancellingBackend: TrashBackend, @unchecked Sendable {
        let inner: DirectoryTrashBackend
        let cancelAfter: Int
        let canceller = LateCanceller()
        private let lock = NSLock()
        private var count = 0
        init(inner: DirectoryTrashBackend, cancelAfter: Int) { self.inner = inner; self.cancelAfter = cancelAfter }
        func trash(_ url: URL) throws -> URL {
            let moved = try inner.trash(url)
            lock.lock(); count += 1; let n = count; lock.unlock()
            if n == cancelAfter { canceller.cancelTask() }
            return moved
        }
    }

    final class FirstMoveClock: TrashBackend, @unchecked Sendable {
        let inner: DirectoryTrashBackend
        private let lock = NSLock()
        private var first: Date?
        init(inner: DirectoryTrashBackend) { self.inner = inner }
        var firstMove: Date? { lock.lock(); defer { lock.unlock() }; return first }
        func trash(_ url: URL) throws -> URL {
            lock.lock(); if first == nil { first = Date() }; lock.unlock()
            return try inner.trash(url)
        }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func runner(_ sandbox: TestSandbox, backend: TrashBackend) -> CleanupRunner {
        CleanupRunner(
            mover: TrashMover(backend: backend, protectedPaths: ProtectedPaths(environment: sandbox.environment)),
            journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: sandbox.environment.logsDirectory),
            sizer: DirectorySizer())
    }

    private func trashDir(_ sandbox: TestSandbox) -> DirectoryTrashBackend {
        DirectoryTrashBackend(directory: sandbox.root.appending(path: "trash", directoryHint: .isDirectory))
    }

    @Test func interruptedRunIsJournaledUpToLastItem() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let files = try (1...4).map { try sandbox.file("home/Library/Caches/f\($0).log", bytes: 10) }
        let backend = CancellingBackend(inner: trashDir(sandbox), cancelAfter: 2)
        let r = runner(sandbox, backend: backend)
        let task = Task {
            await r.run(files, kind: .junkClean, allowedRoots: [root]) { _, _ in }
        }
        backend.canceller.attach(task)
        let record = await task.value
        // Cooperative cancellation: the two finished items stay moved, the rest are recorded as skipped.
        #expect(record.entries.count == 4)
        if case .movedToTrash = record.entries[0].outcome {} else { Issue.record("item 1 not moved") }
        if case .movedToTrash = record.entries[1].outcome {} else { Issue.record("item 2 not moved") }
        #expect(record.entries[2].outcome == .skipped(reason: "cleanup stopped"))
        #expect(record.entries[3].outcome == .skipped(reason: "cleanup stopped"))
        #expect(record.entries[2].originalPath == files[2].path(percentEncoded: false))
        #expect(!record.inProgress)
        let saved = try #require(try RunJournal(directory: sandbox.environment.historyDirectory).all().first)
        #expect(saved.id == record.id && saved.entries == record.entries && !saved.inProgress)
        #expect(try logText(sandbox).contains("skipped: cleanup stopped"))
    }

    @Test func journalOnDiskIsCurrentAfterEveryItemWhileRunning() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let files = try (1...3).map { try sandbox.file("home/Library/Caches/f\($0).log", bytes: 10) }
        let journal = RunJournal(directory: sandbox.environment.historyDirectory)
        let seen = Events()
        _ = await makeRunner(sandbox).run(files, kind: .junkClean, allowedRoots: [root]) { _, _ in
            let onDisk = try? journal.all().first
            seen.add("\(onDisk?.entries.count ?? -1):\(onDisk?.inProgress ?? false)")
        }
        #expect(seen.all == ["1:true", "2:true", "3:true"])
        let final = try #require(try journal.all().first)
        #expect(!final.inProgress)
        #expect(final.entries.count == 3)
        // One header, one line per item, one totals line.
        let lines = try logText(sandbox).split(separator: "\n")
        #expect(lines.count == 5)
        #expect(lines.last?.contains("total:") == true)
    }

    @Test func recoverInterruptedClearsTheFlagAndReturnsTheId() async throws {
        let sandbox = try TestSandbox()
        let journal = RunJournal(directory: sandbox.environment.historyDirectory)
        let stuck = RunRecord(
            startedAt: Date(), kind: .junkClean,
            entries: [JournalEntry(originalPath: "/x/a", bytes: 1, outcome: .skipped(reason: "protected location"))],
            restorable: false, inProgress: true)
        let fine = RunRecord(startedAt: Date(), kind: .junkClean, entries: [], restorable: false)
        try journal.save(stuck)
        try journal.save(fine)
        let ids = try CleanupRunner.recoverInterrupted(journal: journal)
        #expect(ids == [stuck.id])
        let after = try #require(try journal.all().first { $0.id == stuck.id })
        #expect(!after.inProgress)
        #expect(after.entries == stuck.entries)
        #expect(try CleanupRunner.recoverInterrupted(journal: journal).isEmpty)
    }

    @Test func oldRecordsWithoutInProgressDecodeAsFinished() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":"2026-01-01T00:00:00Z","kind":{"junkClean":{}},\
        "entries":[],"restorable":false}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let record = try d.decode(RunRecord.self, from: Data(json.utf8))
        #expect(!record.inProgress)
    }

    @Test func onItemStartPrecedesOnItem() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let a = try sandbox.file("home/Library/Caches/a.log")
        let b = try sandbox.file("home/Library/Caches/b.log")
        let events = Events()
        _ = await makeRunner(sandbox).run(
            [a, b], kind: .junkClean, allowedRoots: [root],
            onItemStart: { events.add("start \($0.lastPathComponent)") },
            onItem: { url, _ in events.add("done \(url.lastPathComponent)") })
        #expect(events.all == ["start a.log", "done a.log", "start b.log", "done b.log"])
    }

    @Test func startedAtIsBeforeFirstMove() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let a = try sandbox.file("home/Library/Caches/a.log")
        let clock = FirstMoveClock(inner: trashDir(sandbox))
        let record = await runner(sandbox, backend: clock).run(
            [a], kind: .junkClean, allowedRoots: [root]) { _, _ in }
        let firstMove = try #require(clock.firstMove)
        #expect(record.startedAt <= firstMove)
    }

    // MARK: failure branches

    private func lockedDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func unlock(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func threeFiles(_ sandbox: TestSandbox) throws -> (URL, [URL]) {
        let root = try sandbox.directory("home/Library/Caches")
        return (root, try (1...3).map { try sandbox.file("home/Library/Caches/f\($0).log", bytes: 10) })
    }

    private func isMoved(_ e: JournalEntry) -> Bool {
        if case .movedToTrash = e.outcome { true } else { false }
    }

    @Test func journalSaveFailureIsRecordedOnce() async throws {
        let sandbox = try TestSandbox()
        let (root, files) = try threeFiles(sandbox)
        let history = sandbox.environment.historyDirectory
        try lockedDirectory(history)
        defer { unlock(history) }
        let record = await makeRunner(sandbox).run(files, kind: .junkClean, allowedRoots: [root]) { _, _ in }
        let historyFailures = record.entries.filter { $0.originalPath == "<history>" }
        #expect(historyFailures.count == 1)
        if case .failed = historyFailures.first?.outcome {} else { Issue.record("<history> entry not failed") }
        let real = record.entries.filter { $0.originalPath != "<history>" }
        #expect(real.count == 3)
        #expect(real.allSatisfy(isMoved))
        // The log still has every item line, plus the history failure.
        let text = try logText(sandbox)
        for f in files { #expect(text.contains(f.path(percentEncoded: false))) }
        #expect(text.contains("<history>"))
        #expect(text.contains("  total:"))
    }

    @Test func logFailureIsRecordedOnceAndJournalKeepsEverything() async throws {
        let sandbox = try TestSandbox()
        let (root, files) = try threeFiles(sandbox)
        let logs = sandbox.environment.logsDirectory
        try lockedDirectory(logs)
        defer { unlock(logs) }
        let record = await makeRunner(sandbox).run(files, kind: .junkClean, allowedRoots: [root]) { _, _ in }
        #expect(record.entries.filter { $0.originalPath == "<log>" }.count == 1)
        let saved = try #require(try RunJournal(directory: sandbox.environment.historyDirectory).all().first)
        #expect(saved.entries.filter { $0.originalPath == "<log>" }.count == 1)
        let real = saved.entries.filter { $0.originalPath != "<log>" }
        #expect(real.map(\.originalPath) == files.map { $0.path(percentEncoded: false) })
        #expect(real.allSatisfy(isMoved))
        #expect(!saved.inProgress)
    }

    @Test func cancelledRunLogEndsWithTotalsIncludingStoppedSkips() async throws {
        let sandbox = try TestSandbox()
        let (root, files) = try threeFiles(sandbox)
        let backend = CancellingBackend(inner: trashDir(sandbox), cancelAfter: 1)
        let r = runner(sandbox, backend: backend)
        let task = Task {
            await r.run(files, kind: .junkClean, allowedRoots: [root]) { _, _ in }
        }
        backend.canceller.attach(task)
        let record = await task.value
        #expect(record.skippedCount == 2)
        let lines = try logText(sandbox).split(separator: "\n")
        let last = try #require(lines.last)
        #expect(last.contains("  total:"))
        #expect(last.contains("0 failed, 0 need admin, 2 skipped"))
        #expect(lines.filter { $0.contains("skipped: cleanup stopped") }.count == 2)
    }
}
