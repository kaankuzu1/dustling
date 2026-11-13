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
        // Just written: it may still be running, so it is left alone.
        #expect(try CleanupRunner.recoverInterrupted(journal: journal).isEmpty)
        #expect(try journal.all().first { $0.id == stuck.id }?.inProgress == true)
        // Quiet for longer than the period: interrupted.
        let later = Date().addingTimeInterval(CleanupRunner.recoveryQuietPeriod + 1)
        let ids = try CleanupRunner.recoverInterrupted(journal: journal, now: later)
        #expect(ids == [stuck.id])
        let after = try #require(try journal.all().first { $0.id == stuck.id })
        #expect(!after.inProgress)
        #expect(after.entries == stuck.entries)
        #expect(try await CleanupRunner.recoverInterruptedInBackground(journal: journal, quietFor: 0).isEmpty)
    }

    @Test func recoveryWithoutOtherWritersSkipsTheQuietPeriod() async throws {
        let sandbox = try TestSandbox()
        let journal = RunJournal(directory: sandbox.environment.historyDirectory)
        let stuck = RunRecord(startedAt: Date(), kind: .junkClean, entries: [], restorable: false, inProgress: true)
        try journal.save(stuck)
        #expect(CleanupRunner.recoveryQuietPeriod(otherWritersRunning: true) == CleanupRunner.recoveryQuietPeriod)
        #expect(CleanupRunner.recoveryQuietPeriod(otherWritersRunning: false) == 0)
        // Another writer runs: a run written just now may be its live run, so it is left alone.
        #expect(try await CleanupRunner.recoverInterruptedInBackground(journal: journal, otherWritersRunning: { true }).isEmpty)
        #expect(try journal.all().first { $0.id == stuck.id }?.inProgress == true)
        // No other writer: nothing can still be writing it, so it is finished off at once.
        #expect(try await CleanupRunner.recoverInterruptedInBackground(journal: journal, otherWritersRunning: { false }) == [stuck.id])
        #expect(try journal.all().first { $0.id == stuck.id }?.inProgress == false)
    }

    @Test func writerProcessesSeesOtherProcessesButNeverItself() {
        // p_comm keeps at most MAXCOMLEN (16) characters.
        let me = String(ProcessInfo.processInfo.processName.prefix(Int(MAXCOMLEN)))
        // launchd and the like are visible; the test process itself is left out.
        #expect(!WriterProcesses.runningNames(excluding: getpid()).isEmpty)
        #expect(WriterProcesses.runningNames(excluding: 0).contains(me))
        #expect(!WriterProcesses.othersRunning(excluding: getpid(), names: ["no-such-process-\(UUID().uuidString.prefix(8))"]))
    }

    @Test func stoppingRecordsThousandsOfRemainingAndExtraItemsInOneSave() throws {
        let sandbox = try TestSandbox()
        let runner = makeRunner(sandbox)
        let home = sandbox.environment.home
        let urls = (0..<5_000).map { home.appending(path: "Library/Caches/item-\($0)") }
        let started = ContinuousClock.now
        // Stopped before the first item: every item is recorded as stopped.
        // Plus the caller's extra entries (in use, unmovable), also written in one batch.
        let extra = (0..<1_000).map { JournalEntry(originalPath: "/in-use/\($0)", bytes: 1, outcome: .skipped(reason: "in use")) }
        let record = runner.runBlocking(
            urls, kind: .junkClean, allowedRoots: [home], extraEntries: extra,
            isCancelled: { true }, onItemStart: { _ in }, onItem: { _, _ in })
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(3), "took \(elapsed)")
        #expect(record.entries.count == 6_000)
        #expect(Array(record.entries.suffix(1_000)) == extra)
        #expect(record.entries.prefix(5_000).allSatisfy {
            if case .skipped(reason: "cleanup stopped") = $0.outcome { true } else { false }
        })
        #expect(!record.inProgress)
        let saved = try #require(try RunJournal(directory: sandbox.environment.historyDirectory).all().first { $0.id == record.id })
        #expect(saved.entries.count == 6_000)
        #expect(!saved.inProgress)
        let lines = try logText(sandbox).split(separator: "\n")
        #expect(lines.count == 6_002)
        #expect(lines.last?.contains("6000 skipped") == true)
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

    // MARK: - Items that belong to the system: one password box per run

    /// A runner whose normal moves go to the sandbox's Trash (where password moves go too).
    private func adminRunner(_ sandbox: TestSandbox, admin: AdminMover?) -> CleanupRunner {
        CleanupRunner(
            mover: TrashMover(backend: DirectoryTrashBackend(directory: sandbox.environment.userTrash),
                              protectedPaths: ProtectedPaths(environment: sandbox.environment)),
            journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: sandbox.environment.logsDirectory),
            sizer: DirectorySizer(), admin: admin)
    }

    /// `a` (a file) and `b` (a folder) in a folder of the system the user can't write, so both need
    /// admin; `c` in the user's own caches. Callers unlock `system` in a `defer`.
    private struct SystemItems: Sendable {
        let system: URL
        let user: URL
        let a: URL
        let b: URL
        let c: URL
        var roots: [URL] { [system, user] }
    }

    private func systemItems(_ sandbox: TestSandbox) throws -> SystemItems {
        try sandbox.directory("home/.Trash")
        let a = try sandbox.file("Library/Application Support/Vendor/a.log", bytes: 10)
        try sandbox.file("Library/Application Support/Vendor/com.example.b/data", bytes: 10)
        let c = try sandbox.file("home/Library/Caches/c.log", bytes: 10)
        let system = sandbox.root.appending(path: "Library/Application Support/Vendor")
        FolderMode.lock(system)
        return SystemItems(
            system: system, user: sandbox.root.appending(path: "home/Library/Caches"), a: a,
            b: sandbox.root.appending(path: "Library/Application Support/Vendor/com.example.b"), c: c)
    }

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    private func trashed(_ sandbox: TestSandbox, _ name: String) -> DeletionOutcome {
        .movedToTrash(trashedPath: path(sandbox.environment.userTrash.appending(path: name)))
    }

    @Test func runnerMovesNeedsAdminItemsWithOnePrompt() async throws {
        let sandbox = try TestSandbox()
        let items = try systemItems(sandbox)
        defer { FolderMode.unlock(items.system) }
        // The script runs as the user: the folder opens again only after planning, as root would find it.
        let shell = UserShell(beforeRun: { FolderMode.unlock(items.system) })
        let admin = AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
        let seen = Collector()
        let record = await adminRunner(sandbox, admin: admin).run(
            [items.a, items.c, items.b], kind: .junkClean, allowedRoots: items.roots) { seen.add($0, $1) }

        #expect(shell.calls.count == 1)
        #expect(shell.calls.first?.prompt == AdminMover.movePrompt(count: 2))
        // c moved at once; a and b after the loop, in one script, each reported once with what happened.
        #expect(record.entries.map(\.originalPath) == [path(items.c), path(items.a), path(items.b)])
        let expected = [trashed(sandbox, "c.log"), trashed(sandbox, "a.log"), trashed(sandbox, "com.example.b")]
        #expect(record.entries.map(\.outcome) == expected)
        #expect(seen.all.map(\.0) == [items.c, items.a, items.b])
        #expect(seen.all.map(\.1) == expected)
        #expect(!FileManager.default.fileExists(atPath: path(items.a)))
        #expect(FileManager.default.fileExists(atPath: path(sandbox.environment.userTrash.appending(path: "com.example.b/data"))))
        // Put back can tell the item from another with the same name: who it is, owner included.
        let identity = try #require(record.entries[1].trashedIdentity)
        #expect(identity == TrashedIdentity.of(path: path(sandbox.environment.userTrash.appending(path: "a.log"))))
        #expect(identity.owner == getuid())
        #expect(record.restorable && record.needsAdminCount == 0 && !record.inProgress)
        let saved = try #require(try RunJournal(directory: sandbox.environment.historyDirectory).all().first)
        #expect(saved.entries == record.entries && !saved.inProgress)
        let text = try logText(sandbox)
        #expect(!text.contains("needs admin"))
        #expect(text.contains("\(path(items.a)) -> \(path(sandbox.environment.userTrash.appending(path: "a.log")))"))
        #expect(text.contains("0 failed, 0 need admin, 0 skipped"))
    }

    @Test func heldItemsAreJournaledBeforeThePasswordStep() async throws {
        // Dustling crashes (or quits at its time limit) while root's script runs: the journal on disk
        // at that moment already lists the held items, as needing admin, after the run's other items.
        let sandbox = try TestSandbox()
        let items = try systemItems(sandbox)
        defer { FolderMode.unlock(items.system) }
        let history = sandbox.environment.historyDirectory
        let snapshot = sandbox.root.appending(path: "history-at-the-password-step", directoryHint: .isDirectory)
        let shell = UserShell(beforeRun: {
            try FileManager.default.copyItem(at: history, to: snapshot)
            FolderMode.unlock(items.system)
        })
        let admin = AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
        let record = await adminRunner(sandbox, admin: admin).run(
            [items.a, items.c, items.b], kind: .junkClean, allowedRoots: items.roots) { _, _ in }
        #expect(shell.calls.count == 1)

        let crashed = RunJournal(directory: snapshot)
        let atTheStep = try #require(try crashed.all().first)
        #expect(atTheStep.id == record.id && atTheStep.inProgress)
        #expect(atTheStep.entries.map(\.originalPath) == [path(items.c), path(items.a), path(items.b)])
        #expect(atTheStep.entries.map(\.outcome) == [trashed(sandbox, "c.log"), .needsAdmin, .needsAdmin])
        // The next launch closes the interrupted run with them in it.
        #expect(try CleanupRunner.recoverInterrupted(journal: crashed, quietFor: 0) == [record.id])
        let recovered = try #require(try crashed.all().first)
        #expect(!recovered.inProgress && recovered.needsAdminCount == 2)
        // The run itself updated them in place, in the same order.
        #expect(record.entries.map(\.originalPath) == [path(items.c), path(items.a), path(items.b)])
        #expect(record.entries.map(\.outcome)
            == [trashed(sandbox, "c.log"), trashed(sandbox, "a.log"), trashed(sandbox, "com.example.b")])
        let saved = try #require(try RunJournal(directory: history).all().first)
        #expect(saved.entries == record.entries && !saved.inProgress)
    }

    @Test func anItemMacOSProtectsIsNeverSentToThePasswordStep() async throws {
        // Even lstat of a data folder macOS keeps to itself fails with EPERM while its folder lists:
        // protected by macOS, recorded as such, and the password box never comes up for it.
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let caches = try sandbox.directory("home/Library/Caches")
        let vault = try sandbox.directory("home/Library/Caches/com.apple.aned")
        let vaultPath = path(vault)
        let mover = TrashMover(
            backend: DirectoryTrashBackend(directory: sandbox.environment.userTrash),
            protectedPaths: ProtectedPaths(environment: sandbox.environment),
            inspectItem: { $0 == vaultPath ? .failed(EPERM) : .failed(ENOENT) })
        let shell = CannedShell(.finished(output: "R\t0\tok\n"))
        let runner = CleanupRunner(
            mover: mover, journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: sandbox.environment.logsDirectory), sizer: DirectorySizer(),
            admin: AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning()))
        let record = await runner.run([vault], kind: .junkClean, allowedRoots: [caches]) { _, _ in }
        #expect(record.entries.map(\.outcome) == [.failed(reason: TrashMover.protectedReason)])
        #expect(shell.calls.isEmpty)
    }

    @Test func systemCachesAndLogsNeverMoveNorReachThePasswordStep() async throws {
        // Dustling never cleans what macOS manages: an item in the system's caches or logs is left
        // where it is, whether the user could move it or only the password could, and nothing asks.
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let caches = try sandbox.directory("Library/Caches")
        let logs = try sandbox.directory("Library/Logs")
        let locked = try sandbox.file("Library/Caches/com.apple.iconservices.store", bytes: 4)
        let open = try sandbox.file("Library/Logs/install.log", bytes: 4)
        FolderMode.lock(caches)
        defer { FolderMode.unlock(caches) }
        let shell = CannedShell(.finished(output: "R\t0\tok\n"))
        let admin = AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
        let record = await adminRunner(sandbox, admin: admin).run(
            [locked, open], kind: .junkClean, allowedRoots: [caches, logs]) { _, _ in }
        let managed = DeletionOutcome.skipped(reason: ProtectedPaths.systemManagedReason)
        #expect(record.entries.map(\.outcome) == [managed, managed])
        #expect(shell.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path(locked)))
        #expect(FileManager.default.fileExists(atPath: path(open)))
    }

    @Test func runnerKeepsNeedsAdminWhenPasswordCancelled() async throws {
        let sandbox = try TestSandbox()
        let items = try systemItems(sandbox)
        defer { FolderMode.unlock(items.system) }
        let shell = CannedShell(.cancelled)
        let admin = AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
        let seen = Collector()
        let record = await adminRunner(sandbox, admin: admin).run(
            [items.a, items.c, items.b], kind: .junkClean, allowedRoots: items.roots) { seen.add($0, $1) }
        #expect(shell.calls.count == 1)
        #expect(record.entries.map(\.outcome) == [trashed(sandbox, "c.log"), .needsAdmin, .needsAdmin])
        #expect(seen.all.map(\.0) == [items.c, items.a, items.b])
        #expect(seen.all.map(\.1) == [trashed(sandbox, "c.log"), .needsAdmin, .needsAdmin])
        #expect(FileManager.default.fileExists(atPath: path(items.a)))
        #expect(FileManager.default.fileExists(atPath: path(items.b)))
        #expect(record.needsAdminCount == 2)
        #expect(try logText(sandbox).contains("0 failed, 2 need admin, 0 skipped"))
    }

    @Test func runnerWithoutAdminIsUnchanged() async throws {
        let sandbox = try TestSandbox()
        let items = try systemItems(sandbox)
        defer { FolderMode.unlock(items.system) }
        let seen = Collector()
        let record = await adminRunner(sandbox, admin: nil).run(
            [items.a, items.c, items.b], kind: .junkClean, allowedRoots: items.roots) { seen.add($0, $1) }
        #expect(record.entries.map(\.originalPath) == [path(items.a), path(items.c), path(items.b)])
        #expect(record.entries.map(\.outcome) == [.needsAdmin, trashed(sandbox, "c.log"), .needsAdmin])
        #expect(seen.all.map(\.0) == [items.a, items.c, items.b])
        #expect(FileManager.default.fileExists(atPath: path(items.a)))
    }

    @Test func stoppedRunNeverAsksForPassword() throws {
        // Stopped before the last item, and stopped during the last item (before the password step).
        for (stopAt, urls) in [(3, ["a", "c", "b"]), (3, ["a", "c"])] {
            let sandbox = try TestSandbox()
            let items = try systemItems(sandbox)
            defer { FolderMode.unlock(items.system) }
            let byName = ["a": items.a, "b": items.b, "c": items.c]
            let shell = CannedShell(.finished(output: ""))
            let admin = AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
            var checks = 0
            var reported: [(URL, DeletionOutcome)] = []
            let record = adminRunner(sandbox, admin: admin).runBlocking(
                urls.compactMap { byName[$0] }, kind: .junkClean, allowedRoots: items.roots, extraEntries: [],
                isCancelled: { checks += 1; return checks >= stopAt }, onItemStart: { _ in },
                onItem: { reported.append(($0, $1)) })
            let stopped = DeletionOutcome.skipped(reason: "cleanup stopped")
            #expect(shell.calls.isEmpty)
            #expect(FileManager.default.fileExists(atPath: path(items.a)))
            // The held item is recorded as stopped (reported once), before the items never attempted.
            var expected = [trashed(sandbox, "c.log"), stopped]
            if urls.count == 3 { expected.append(stopped) }
            #expect(record.entries.map(\.outcome) == expected)
            #expect(record.entries.prefix(2).map(\.originalPath) == [path(items.c), path(items.a)])
            #expect(reported.map(\.0) == [items.c, items.a])
            #expect(reported.map(\.1) == [trashed(sandbox, "c.log"), stopped])
            #expect(!record.inProgress)
        }
    }

    @Test func runnerKeepsNeedsAdminWhenAFolderCantBeOpened() async throws {
        // Planning reads every folder a step acts in through a descriptor. A folder Dustling can't
        // open (here search-only; for ~/.Trash, missing Full Disk Access) means the password can't
        // help yet: nothing is asked and the item still needs admin, never "macOS refused".
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let sealed = try sandbox.directory("Library/Sealed")
        let hidden = try sandbox.file("Library/Sealed/a.log")
        let items = try systemItems(sandbox)
        FolderMode.set(sealed, 0o111)
        defer {
            FolderMode.unlock(sealed)
            FolderMode.unlock(items.system)
            FolderMode.unlock(trash)
        }
        let shell = CannedShell(.finished(output: ""))
        let admin = AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
        let roots = items.roots + [sealed]
        let first = await adminRunner(sandbox, admin: admin).run([hidden], kind: .junkClean, allowedRoots: roots) { _, _ in }
        #expect(first.entries.map(\.outcome) == [.needsAdmin])
        // The Trash itself can't be opened.
        FolderMode.set(trash, 0o111)
        let second = await adminRunner(sandbox, admin: admin).run([items.a], kind: .junkClean, allowedRoots: roots) { _, _ in }
        #expect(second.entries.map(\.outcome) == [.needsAdmin])
        #expect(shell.calls.isEmpty)
    }

    @Test func runnerSaysWhatThePasswordStepReported() async throws {
        let sandbox = try TestSandbox()
        let items = try systemItems(sandbox)
        defer { FolderMode.unlock(items.system) }
        let d = items.system.appending(path: "d.log")
        FolderMode.unlock(items.system)
        try Data(count: 1).write(to: d)
        FolderMode.lock(items.system)
        let shell = CannedShell(.finished(output: "R\t0\terr\nB\t/Library/.dustling-test\nR\t1\theld\nR\t2\tgone\n"))
        let admin = AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
        let record = await adminRunner(sandbox, admin: admin).run(
            [items.a, items.b, d], kind: .junkClean, allowedRoots: items.roots) { _, _ in }
        #expect(record.entries.map(\.outcome) == [
            .failed(reason: "macOS refused, even with your password"),
            .failed(reason: "Something changed while it was moving, so Dustling stopped. It is untouched in /Library/.dustling-test."),
            .skipped(reason: "already gone"),
        ])
        #expect(!record.restorable)
    }

    @Test func heldItemGetsItsTrashNameOnlyRightBeforeThePasswordStep() async throws {
        // A system item held early in the run must not lose its name in the Trash to a later item
        // of the run that moves the normal way: names are chosen right before the password step.
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let system = try sandbox.file("Library/Application Support/Vendor/x.log", bytes: 3)
        let mine = try sandbox.file("home/Library/Caches/x.log", bytes: 3)
        let folder = system.deletingLastPathComponent()
        FolderMode.lock(folder)
        defer { FolderMode.unlock(folder) }
        let shell = UserShell(beforeRun: { FolderMode.unlock(folder) })
        let admin = AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
        let record = await adminRunner(sandbox, admin: admin).run(
            [system, mine], kind: .junkClean,
            allowedRoots: [folder, mine.deletingLastPathComponent()]) { _, _ in }
        #expect(shell.calls.count == 1)
        #expect(record.entries.map(\.originalPath) == [path(mine), path(system)])
        #expect(record.entries.map(\.outcome) == [trashed(sandbox, "x.log"), trashed(sandbox, "x 2.log")])
        #expect(!FileManager.default.fileExists(atPath: path(system)))
    }
}
