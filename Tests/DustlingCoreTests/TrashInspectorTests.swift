import Foundation
import Testing
@testable import DustlingCore

struct TrashInspectorTests {
    private func makeInspector(_ sandbox: TestSandbox, logsDirectory: URL? = nil) -> (TrashInspector, RunJournal) {
        let journal = RunJournal(directory: sandbox.environment.historyDirectory)
        let inspector = TrashInspector(
            environment: sandbox.environment, journal: journal,
            logger: RunLogger(directory: logsDirectory ?? sandbox.environment.logsDirectory),
            sizer: DirectorySizer())
        return (inspector, journal)
    }

    private func uid(_ sandbox: TestSandbox) -> String { String(sandbox.environment.userID) }

    @Test func includesExternalVolumeTrash() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/a.bin", bytes: 4096)
        let ext = try sandbox.file("Volumes/Ext/.Trashes/\(uid(sandbox))/f.bin", bytes: 8192)
        try sandbox.directory("Volumes/Other")   // no trash on this volume
        let (inspector, _) = makeInspector(sandbox)
        let locations = inspector.trashLocations().map(\.standardizedFileURL.path)
        #expect(locations.count == 2)
        #expect(locations.contains(ext.deletingLastPathComponent().standardizedFileURL.path))
        let size = inspector.size()
        #expect(size.fileCount == 2)
        #expect(size.bytes == DirectorySizer().measure(ext).bytes + DirectorySizer().measure(
            sandbox.root.appending(path: "home/.Trash/a.bin")).bytes)
        #expect(size.unreadable.isEmpty)
    }

    @Test func emptyTrashDeletesAndReports() throws {
        let sandbox = try TestSandbox()
        let a = try sandbox.file("home/.Trash/a.bin", bytes: 4096)
        try sandbox.file("home/.Trash/dir/b.bin", bytes: 4096)
        let sizeA = DirectorySizer().measure(a).bytes
        let (inspector, journal) = makeInspector(sandbox)
        let before = Date()
        let record = inspector.emptyTrash()
        #expect(record.kind == .emptyTrash)
        #expect(record.restorable == false)
        #expect(record.startedAt >= before)
        #expect(record.entries.count == 2)
        #expect(record.entries.allSatisfy { $0.outcome == .deleted })
        #expect(record.entries.first { $0.originalPath.hasSuffix("a.bin") }?.bytes == sizeA)
        let left = try FileManager.default.contentsOfDirectory(atPath: sandbox.environment.userTrash.path)
        #expect(left.isEmpty)
        #expect(try journal.all().map(\.id) == [record.id])
        let logs = try FileManager.default.contentsOfDirectory(
            at: sandbox.environment.logsDirectory, includingPropertiesForKeys: nil)
        #expect(logs.count == 1)
    }

    @Test func emptyTrashMakesEarlierRunsNotRestorable() throws {
        let sandbox = try TestSandbox()
        let (inspector, journal) = makeInspector(sandbox)
        let earlier = RunRecord(
            startedAt: Date(), kind: .junkClean,
            entries: [JournalEntry(
                originalPath: "/x", bytes: 1,
                outcome: .movedToTrash(trashedPath: sandbox.root.appending(path: "home/.Trash/gone").path))],
            restorable: true)
        try journal.save(earlier)
        try sandbox.file("home/.Trash/other.bin")
        _ = inspector.emptyTrash()
        let reloaded = try #require(try journal.all().first { $0.id == earlier.id })
        #expect(reloaded.restorable == false)
    }

    @Test func undeletableItemIsReported() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/ok.bin")
        let locked = try sandbox.file("home/.Trash/locked/inner.bin")
        let lockedDir = locked.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path) }
        let (inspector, _) = makeInspector(sandbox)
        let record = inspector.emptyTrash()
        #expect(record.entries.count == 2)
        let lockedEntry = try #require(record.entries.first { $0.originalPath.hasSuffix("locked") })
        guard case .failed = lockedEntry.outcome else { Issue.record("expected failed"); return }
        #expect(record.entries.first { $0.originalPath.hasSuffix("ok.bin") }?.outcome == .deleted)
        #expect(FileManager.default.fileExists(atPath: locked.path))
    }

    @Test func symlinkInTrashIsRemovedWithoutTouchingTarget() throws {
        let sandbox = try TestSandbox()
        let outside = try sandbox.file("outside/keep.txt", bytes: 10)
        try sandbox.directory("home/.Trash")
        let link = sandbox.environment.userTrash.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let (inspector, _) = makeInspector(sandbox)
        let record = inspector.emptyTrash()
        #expect(record.entries.count == 1)
        #expect(record.entries[0].outcome == .deleted)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }

    @Test func unreadableLocationIsReportedNotSkipped() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/a.bin")
        let trash = sandbox.environment.userTrash
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trash.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path) }
        let (inspector, _) = makeInspector(sandbox)
        #expect(inspector.size().unreadable.count == 1)
        let record = inspector.emptyTrash()
        #expect(record.entries.count == 1)
        #expect(record.entries[0].originalPath == trash.path)
        #expect(record.entries[0].outcome == .failed(reason: "no access, grant Full Disk Access"))
    }

    @Test func missingTrashIsNotALocation() throws {
        let sandbox = try TestSandbox()
        let (inspector, _) = makeInspector(sandbox)
        #expect(inspector.trashLocations().isEmpty)
        let record = inspector.emptyTrash()
        #expect(record.entries.isEmpty)
        #expect(record.kind == .emptyTrash)
    }

    @Test func logFailureIsReportedOnTheRecord() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/a.bin")
        let blocker = try sandbox.file("blocker")   // a file where the log directory should be
        let (inspector, _) = makeInspector(sandbox, logsDirectory: blocker.appending(path: "logs"))
        let record = inspector.emptyTrash()
        #expect(record.entries.contains { $0.originalPath == "<log>" && $0.bytes == 0 })
    }
}
