import Foundation
import Testing
@testable import DustlingCore

struct TrashMoverTests {
    struct Boom: LocalizedError {
        var errorDescription: String? { "disk exploded" }
    }
    struct ThrowingBackend: TrashBackend {
        func trash(_ url: URL) throws -> URL { throw Boom() }
    }

    struct FailingBackend: TrashBackend {
        let error: Error
        func trash(_ url: URL) throws -> URL { throw error }
    }

    @Test func trashRefusedWithEPERMIsProtected() throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log")
        let error = CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])
        let (mover, _) = make(sandbox, backend: FailingBackend(error: error))
        #expect(mover.moveToTrash(file, allowedRoots: [root]) == .failed(reason: "protected by macOS"))
        #expect(TrashMover.protectedReason == TrashUnlocker.protectedReason)
    }

    @Test func trashRefusedWithEACCESKeepsDescription() throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log")
        let error = CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)])
        let (mover, _) = make(sandbox, backend: FailingBackend(error: error))
        #expect(mover.moveToTrash(file, allowedRoots: [root]) == .failed(reason: error.localizedDescription))
    }

    private func make(_ sandbox: TestSandbox, backend: TrashBackend? = nil) -> (TrashMover, URL) {
        let trash = sandbox.root.appending(path: "trash", directoryHint: .isDirectory)
        let mover = TrashMover(
            backend: backend ?? DirectoryTrashBackend(directory: trash),
            protectedPaths: ProtectedPaths(environment: sandbox.environment))
        return (mover, trash)
    }

    @Test func movesAllowedItem() throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log")
        let (mover, trash) = make(sandbox)
        let outcome = mover.moveToTrash(file, allowedRoots: [root])
        #expect(outcome == .movedToTrash(trashedPath: trash.appending(path: "a.log").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func protectedItemIsSkippedWithReason() throws {
        let sandbox = try TestSandbox()
        let file = try sandbox.file("home/Documents/x.txt")
        let (mover, _) = make(sandbox)
        let outcome = mover.moveToTrash(file, allowedRoots: [sandbox.root.appending(path: "home")])
        #expect(outcome == .skipped(reason: "protected location"))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func missingItemIsSkipped() throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let (mover, _) = make(sandbox)
        let outcome = mover.moveToTrash(root.appending(path: "nope"), allowedRoots: [root])
        #expect(outcome == .skipped(reason: "already gone"))
    }

    @Test func danglingSymlinkIsNotMissing() throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let link = root.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent-target")
        let (mover, _) = make(sandbox)
        guard case .movedToTrash = mover.moveToTrash(link, allowedRoots: [root]) else {
            Issue.record("dangling symlink should be trashed")
            return
        }
    }

    @Test func unwritableParentNeedsAdmin() throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        let (mover, _) = make(sandbox)
        #expect(mover.moveToTrash(file, allowedRoots: [root]) == .needsAdmin)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unwritableDirectoryNeedsAdmin() throws {
        // Moving a directory to another folder rewrites its "..", which needs write access to it.
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let locked = try sandbox.directory("home/Library/Caches/locked")
        try sandbox.file("home/Library/Caches/locked/inner.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let (mover, _) = make(sandbox)
        #expect(mover.moveToTrash(locked, allowedRoots: [root]) == .needsAdmin)
        #expect(FileManager.default.fileExists(atPath: locked.path))
    }

    @Test func unreadableFileInWritableFolderIsStillMovable() throws {
        // Only directories need write access on themselves; a read-only file moves fine.
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/ro.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let (mover, _) = make(sandbox)
        guard case .movedToTrash = mover.moveToTrash(file, allowedRoots: [root]) else {
            Issue.record("read-only file should move"); return
        }
    }

    @Test func itemInsideUnreadableFolderFailsWithAccessHint() throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let sealed = try sandbox.directory("home/Library/Caches/sealed")
        let item = try sandbox.file("home/Library/Caches/sealed/item.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealed.path) }
        let (mover, _) = make(sandbox)
        #expect(mover.moveToTrash(item, allowedRoots: [root])
            == .failed(reason: "no access (Full Disk Access may be needed)"))
    }

    @Test func pathThroughAFileIsAlreadyGone() throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log")
        let (mover, _) = make(sandbox)
        #expect(mover.moveToTrash(file.appending(path: "child"), allowedRoots: [root])
            == .skipped(reason: "already gone"))
    }

    // MARK: - Permission decision (stat data and access() errnos injected: other owners need root and
    // TCC denials can't be set up in a sandbox)

    private func facts(
        parentAccess: Int32 = 0, sticky: Bool = false, parentOwner: uid_t = 501,
        directory: Bool = false, itemAccess: Int32 = 0, itemOwner: uid_t = 501
    ) -> TrashMover.PermissionFacts {
        TrashMover.PermissionFacts(
            parentAccess: parentAccess, parentIsSticky: sticky, parentOwner: parentOwner,
            itemIsDirectory: directory, itemAccess: itemAccess, itemOwner: itemOwner, userID: 501)
    }

    private let noAccess = TrashMover.PermissionDecision.failed(reason: "no access (Full Disk Access may be needed)")

    @Test func needsAdminDecision() {
        #expect(TrashMover.decide(facts()) == .allowed)
        #expect(TrashMover.decide(facts(parentAccess: EACCES)) == .needsAdmin)
        #expect(TrashMover.decide(facts(directory: true, itemAccess: EACCES)) == .needsAdmin)
        #expect(TrashMover.decide(facts(directory: false, itemAccess: EACCES)) == .allowed)
        // Sticky parent (like /tmp): someone else's item in someone else's folder can't be moved.
        #expect(TrashMover.decide(facts(sticky: true, parentOwner: 0, itemOwner: 0)) == .needsAdmin)
        #expect(TrashMover.decide(facts(sticky: true, parentOwner: 0, itemOwner: 501)) == .allowed)
        #expect(TrashMover.decide(facts(sticky: true, parentOwner: 501, itemOwner: 0)) == .allowed)
        #expect(TrashMover.decide(facts(sticky: false, parentOwner: 0, itemOwner: 0)) == .allowed)
    }

    /// macOS access() says EPERM for TCC-protected folders the user owns (e.g. ~/Library/Caches/com.apple.Safari
    /// without Full Disk Access): admin rights wouldn't help, Full Disk Access would.
    @Test func privacyDenialIsNoAccessNotNeedsAdmin() {
        #expect(TrashMover.decide(facts(directory: true, itemAccess: EPERM)) == noAccess)
        #expect(TrashMover.decide(facts(parentAccess: EPERM)) == noAccess)
        #expect(TrashMover.decide(facts(parentAccess: EACCES, directory: true, itemAccess: EPERM)) == noAccess)
        #expect(TrashMover.decide(facts(parentAccess: EPERM, sticky: true, parentOwner: 0, itemOwner: 0)) == noAccess)
    }

    @Test func otherAccessErrorsFailWithTheirDescription() {
        #expect(TrashMover.decide(facts(parentAccess: EROFS)) == .failed(reason: "Read-only file system"))
        #expect(TrashMover.decide(facts(directory: true, itemAccess: EROFS)) == .failed(reason: "Read-only file system"))
    }

    @Test func backendErrorBecomesFailedWithReason() throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.directory("home/Library/Caches")
        let file = try sandbox.file("home/Library/Caches/a.log")
        let (mover, _) = make(sandbox, backend: ThrowingBackend())
        guard case .failed(let reason) = mover.moveToTrash(file, allowedRoots: [root]) else {
            Issue.record("expected failed")
            return
        }
        #expect(reason.contains("disk exploded"))
    }

    @Test func directoryBackendNamesCollisionsLikeFinder() throws {
        let sandbox = try TestSandbox()
        let backend = DirectoryTrashBackend(directory: sandbox.root.appending(path: "trash"))
        let a = try backend.trash(try sandbox.directory("x/Caches"))
        let b = try backend.trash(try sandbox.directory("y/Caches"))
        let c = try backend.trash(try sandbox.file("z/a.log"))
        let d = try backend.trash(try sandbox.file("w/a.log"))
        #expect([a, b, c, d].map(\.lastPathComponent) == ["Caches", "Caches 2", "a.log", "a 2.log"])
    }

    @Test func labelsAreVerbatim() throws {
        #expect(DeletionOutcome.movedToTrash(trashedPath: "/t").label == "moved to Trash")
        #expect(DeletionOutcome.skipped(reason: "r").label == "skipped: r")
        #expect(DeletionOutcome.failed(reason: "r").label == "failed: r")
        #expect(DeletionOutcome.needsAdmin.label == "needs admin")
        #expect(DeletionOutcome.deleted.label == "deleted")
        let data = try JSONEncoder().encode(DeletionOutcome.movedToTrash(trashedPath: "/t"))
        #expect(try JSONDecoder().decode(DeletionOutcome.self, from: data) == .movedToTrash(trashedPath: "/t"))
    }
}
