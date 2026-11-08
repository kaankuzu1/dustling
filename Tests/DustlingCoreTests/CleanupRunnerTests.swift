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
}

