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
        // Claim to be another user so the folder isn't unlocked (it would be, for its owner).
        var environment = sandbox.environment
        environment.userID = 503
        let inspector = TrashInspector(
            environment: environment,
            journal: RunJournal(directory: environment.historyDirectory),
            logger: RunLogger(directory: environment.logsDirectory), sizer: DirectorySizer(),
            includeExternalVolumes: false, inspect: TrashInspector.lstatKind, blocker: { _, _ in nil })
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

    // MARK: - Symlinked trash locations

    private static let symlinkReason = "trash location is a symbolic link, not emptied"

    private func link(_ at: URL, to target: URL) throws {
        try FileManager.default.createDirectory(
            at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: at, withDestinationURL: target)
    }

    /// /var vs /private/var: listing a directory may report the resolved prefix.
    private func norm(_ path: String?) -> String? {
        path.map { $0.hasPrefix("/private/") ? String($0.dropFirst("/private".count)) : $0 }
    }

    private func expectRefused(_ sandbox: TestSandbox, location: URL, survivor: URL) {
        let (inspector, _) = makeInspector(sandbox)
        #expect(inspector.size().unreadable.map { norm($0.path) } == [norm(location.path)])
        #expect(inspector.size().bytes == 0)
        let record = inspector.emptyTrash()
        #expect(record.entries.count == 1)
        #expect(norm(record.entries.first?.originalPath) == norm(location.path))
        #expect(record.entries.first?.bytes == 0)
        #expect(record.entries.first?.outcome == .failed(reason: Self.symlinkReason))
        #expect(FileManager.default.fileExists(atPath: survivor.path))
    }

    @Test func symlinkedHomeTrashIsRefused() throws {
        let sandbox = try TestSandbox()
        let outside = try sandbox.file("outside/precious.txt")
        try link(sandbox.environment.userTrash, to: outside.deletingLastPathComponent())
        expectRefused(sandbox, location: sandbox.environment.userTrash, survivor: outside)
    }

    @Test func symlinkedTrashesDirectoryIsRefused() throws {
        let sandbox = try TestSandbox()
        let outside = try sandbox.file("outside/\(uid(sandbox))/f")
        let vol = sandbox.environment.volumesDirectory.appending(path: "Ext")
        try link(vol.appending(path: ".Trashes"), to: outside.deletingLastPathComponent().deletingLastPathComponent())
        expectRefused(
            sandbox, location: vol.appending(path: ".Trashes/\(uid(sandbox))"), survivor: outside)
    }

    @Test func symlinkedUidTrashIsRefused() throws {
        let sandbox = try TestSandbox()
        let outside = try sandbox.file("outside/f")
        let vol = sandbox.environment.volumesDirectory.appending(path: "Ext")
        let loc = vol.appending(path: ".Trashes/\(uid(sandbox))")
        try link(loc, to: outside.deletingLastPathComponent())
        expectRefused(sandbox, location: loc, survivor: outside)
    }

    @Test func symlinkedVolumeEntryIsSkipped() throws {
        let sandbox = try TestSandbox()
        let f = try sandbox.file("bootdir/.Trashes/\(uid(sandbox))/f")
        try link(sandbox.environment.volumesDirectory.appending(path: "Boot"),
                 to: sandbox.root.appending(path: "bootdir"))
        let (inspector, _) = makeInspector(sandbox)
        #expect(inspector.trashLocations().isEmpty)
        #expect(inspector.size().unreadable.isEmpty)
        let record = inspector.emptyTrash()
        #expect(record.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.path))
    }

    /// Uses the internal `inspect` seam to make `lstat` of a volume entry fail, which genuinely
    /// exercises the `.denied` / `.other` volume branches (a real filesystem arrangement cannot:
    /// listing the volumes directory fails first when its children are not statable).
    @Test(arguments: [
        (TrashInspector.Kind.denied, "no access, grant Full Disk Access"),
        (TrashInspector.Kind.other("Input/output error"), "Input/output error"),
    ])
    func uninspectableVolumeIsReported(kind: TrashInspector.Kind, reason: String) throws {
        let sandbox = try TestSandbox()
        let ext = try sandbox.directory("Volumes/Ext")
        try sandbox.directory("Volumes/Fine")
        let inspector = TrashInspector(
            environment: sandbox.environment,
            journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: sandbox.environment.logsDirectory),
            sizer: DirectorySizer(),
            inspect: { url in url.lastPathComponent == "Ext" ? kind : TrashInspector.lstatKind(url) })
        let expected = norm(ext.appending(path: ".Trashes/\(uid(sandbox))").path)
        #expect(inspector.size().unreadable.map { norm($0.path) } == [expected])
        let record = inspector.emptyTrash()
        #expect(record.entries.count == 1)
        #expect(norm(record.entries[0].originalPath) == expected)
        #expect(record.entries[0].bytes == 0)
        #expect(record.entries[0].outcome == .failed(reason: reason))
    }
    // MARK: - Size issues and contents (Important #5, Important #1)

    @Test func deniedLocationIsAFullDiskAccessIssue() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/a.bin")
        let trash = sandbox.environment.userTrash
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trash.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path) }
        let (inspector, _) = makeInspector(sandbox)
        let result = inspector.sizeWithIssues()
        #expect(result.issues == [.missingFullDiskAccess(trash)])
        #expect(result.size.bytes == 0)
        #expect(result.size == inspector.size())
    }

    @Test func symlinkedLocationIsAnUnreadableIssue() throws {
        let sandbox = try TestSandbox()
        let outside = try sandbox.file("outside/precious.txt")
        try link(sandbox.environment.userTrash, to: outside.deletingLastPathComponent())
        let (inspector, _) = makeInspector(sandbox)
        let issues = inspector.sizeWithIssues().issues
        #expect(issues.count == 1)
        guard case .unreadable(let url)? = issues.first else { Issue.record("expected unreadable"); return }
        #expect(norm(url.path) == norm(sandbox.environment.userTrash.path))
    }

    @Test(arguments: [
        (TrashInspector.Kind.denied, true),
        (TrashInspector.Kind.other("Input/output error"), false),
    ])
    func uninspectableVolumeIssueKind(kind: TrashInspector.Kind, isAccess: Bool) throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("Volumes/Ext")
        let inspector = TrashInspector(
            environment: sandbox.environment,
            journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: sandbox.environment.logsDirectory),
            sizer: DirectorySizer(),
            inspect: { url in url.lastPathComponent == "Ext" ? kind : TrashInspector.lstatKind(url) })
        let issues = inspector.sizeWithIssues().issues
        #expect(issues.count == 1)
        switch issues.first {
        case .missingFullDiskAccess?: #expect(isAccess)
        case .unreadable?: #expect(!isAccess)
        default: Issue.record("unexpected \(issues)")
        }
    }

    @Test func unreadableItemInsideTheTrashIsReported() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/ok.bin", bytes: 4096)
        let locked = try sandbox.directory("home/.Trash/locked")
        try sandbox.file("home/.Trash/locked/inner.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let (inspector, _) = makeInspector(sandbox)
        let contents = inspector.contents()
        #expect(contents.issues.map { if case .missingFullDiskAccess(let u) = $0 { norm(u.path) } else { nil } }
            == [norm(locked.path)])
        #expect(contents.items.map(\.url.lastPathComponent).sorted() == ["locked", "ok.bin"])
        #expect(contents.size.bytes > 0)
    }

    @Test func contentsListsTopLevelItemsWithSizes() throws {
        let sandbox = try TestSandbox()
        let a = try sandbox.file("home/.Trash/a.bin", bytes: 4096)
        try sandbox.file("home/.Trash/dir/b.bin", bytes: 8192)
        try sandbox.file("home/.Trash/dir/c.bin", bytes: 8192)
        let ext = try sandbox.file("Volumes/Ext/.Trashes/\(uid(sandbox))/e.bin", bytes: 4096)
        let (inspector, _) = makeInspector(sandbox)
        let contents = inspector.contents()
        #expect(contents.issues.isEmpty)
        #expect(contents.items.map(\.url.lastPathComponent).sorted() == ["a.bin", "dir", "e.bin"])
        let dir = try #require(contents.items.first { $0.url.lastPathComponent == "dir" })
        #expect(dir.size.fileCount == 2)
        #expect(contents.items.first { $0.url.lastPathComponent == "a.bin" }?.size.bytes == DirectorySizer().measure(a).bytes)
        #expect(contents.size.bytes == contents.items.reduce(0) { $0 + $1.size.bytes })
        #expect(contents.size.fileCount == 4)
        #expect(contents.items.contains { norm($0.url.path) == norm(ext.path) })
    }

    @Test func emptyTrashHasNoItemsAndNoIssues() throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let (inspector, _) = makeInspector(sandbox)
        let contents = inspector.contents()
        #expect(contents.items.isEmpty && contents.issues.isEmpty && contents.size.bytes == 0)
    }

    @Test func emptyTrashDeletesLockedOwnItems() throws {
        let sandbox = try TestSandbox()
        let file = try sandbox.file("home/.Trash/locked/a.bin", bytes: 64)
        let folder = file.deletingLastPathComponent()
        _ = chflags(file.path, UInt32(UF_IMMUTABLE))
        _ = chmod(folder.path, 0o555)
        defer { _ = chflags(file.path, 0); _ = chmod(folder.path, 0o755) }
        let (inspector, _) = makeInspector(sandbox)
        let record = inspector.emptyTrash()
        #expect(record.entries.count == 1)
        #expect(record.entries.allSatisfy { $0.outcome == .deleted })
        let left = try FileManager.default.contentsOfDirectory(atPath: sandbox.environment.userTrash.path)
        #expect(left.isEmpty)
    }

    @Test func mixedOwnershipReportsNeedsAdmin() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/ok.bin", bytes: 8)
        let stuck = try sandbox.file("home/.Trash/TI App/inner.bin", bytes: 8)
        let dir = stuck.deletingLastPathComponent()
        _ = chmod(dir.path, 0o555)
        defer { _ = chmod(dir.path, 0o755) }
        // The environment claims to be uid 503, so the read-only folder isn't "ours" and stays
        // locked: a real removal failure. The injected blocker says why.
        var environment = sandbox.environment
        environment.userID = 503
        let inspector = TrashInspector(
            environment: environment,
            journal: RunJournal(directory: environment.historyDirectory),
            logger: RunLogger(directory: environment.logsDirectory), sizer: DirectorySizer(),
            includeExternalVolumes: false, inspect: TrashInspector.lstatKind,
            blocker: { url, _ in url.lastPathComponent == "TI App" ? .otherOwner(count: 2) : nil })
        let record = inspector.emptyTrash()
        func outcome(_ name: String) -> DeletionOutcome? {
            record.entries.first { $0.originalPath.hasSuffix(name) }?.outcome
        }
        #expect(outcome("ok.bin") == .deleted)
        #expect(outcome("TI App") == .needsAdmin)
    }
}

