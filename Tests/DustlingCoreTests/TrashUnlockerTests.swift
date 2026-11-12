import Foundation
import Testing
@testable import DustlingCore

struct TrashUnlockerTests {
    private let fm = FileManager.default

    private func makeLocked(_ sandbox: TestSandbox, under parent: String) throws -> (folder: URL, file: URL) {
        let file = try sandbox.file("\(parent)/locked/a.bin", bytes: 64)
        let folder = file.deletingLastPathComponent()
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chmod(folder.path, 0o555) == 0)
        return (folder, file)
    }

    private func restore(_ urls: URL...) {
        for url in urls {
            _ = chflags(url.path, 0)
            _ = chmod(url.path, 0o755)
        }
    }

    @Test func unlockClearsUserImmutableAndReadOnlyDirectories() throws {
        let sandbox = try TestSandbox()
        let (folder, file) = try makeLocked(sandbox, under: "home/.Trash")
        defer { restore(file, folder) }
        #expect(throws: (any Error).self) { try fm.removeItem(at: folder) }
        let changed = TrashUnlocker.unlockOwnItems(in: folder, userID: getuid())
        #expect(changed >= 2)
        try fm.removeItem(at: folder)
        #expect(!fm.fileExists(atPath: folder.path))
    }

    @Test func unlockNeverFollowsSymlinks() throws {
        let sandbox = try TestSandbox()
        let (outside, target) = try makeLocked(sandbox, under: "outside")
        defer { restore(target, outside) }
        let link = sandbox.root.appending(path: "home/.Trash/link")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        _ = TrashUnlocker.unlockOwnItems(in: link, userID: getuid())
        var st = stat()
        #expect(lstat(outside.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o555)
        #expect(lstat(target.path, &st) == 0)
        #expect(st.st_flags & UInt32(UF_IMMUTABLE) != 0)
    }

    @Test func foreignOwnerInReadOnlyFolderIsCounted() throws {
        let sandbox = try TestSandbox()
        let a = try sandbox.file("home/.Trash/pkg/Contents/a", bytes: 8)
        try sandbox.file("home/.Trash/pkg/Contents/b", bytes: 8)
        let dir = a.deletingLastPathComponent()
        _ = chmod(dir.path, 0o555)
        defer { restore(dir) }
        let result = TrashUnlocker.blocker(
            of: sandbox.root.appending(path: "home/.Trash/pkg"), userID: getuid(),
            owner: { $0.lastPathComponent == "a" || $0.lastPathComponent == "b" ? getuid() &+ 1 : getuid() })
        #expect(result == .otherOwner(count: 2))
    }

    @Test func ownItemsHaveNoBlocker() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/x/y", bytes: 8)
        #expect(TrashUnlocker.blocker(of: sandbox.root.appending(path: "home/.Trash/x"), userID: getuid()) == nil)
    }

    @Test func userOwnedEntryThatFailsWithEPERMIsProtected() throws {
        let sandbox = try TestSandbox()
        let dir = try sandbox.directory("home/.Trash/x/Private")
        let root = sandbox.root.appending(path: "home/.Trash/x")
        defer { restore(dir) }
        #expect(chmod(dir.path, 0o000) == 0)
        // Real fts error here is EACCES; a protected folder reports EPERM, so inject that.
        let plain = TrashUnlocker.blocker(of: root, userID: getuid(), owner: { _ in getuid() })
        #expect(plain == nil)
        let injected = TrashUnlocker.blocker(
            of: root, userID: getuid(), owner: { _ in getuid() },
            failure: { $0.lastPathComponent == "Private" ? EPERM : nil })
        #expect(injected == .protectedByMacOS)
    }

    @Test func hardLinkedLockedFileKeepsItsFlagAndIsReported() throws {
        let sandbox = try TestSandbox()
        let outside = try sandbox.file("outside/data.bin", bytes: 8)
        let linked = sandbox.root.appending(path: "home/.Trash/data.bin")
        try fm.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.linkItem(at: outside, to: linked)
        #expect(chflags(linked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { restore(outside, linked) }
        #expect(TrashUnlocker.unlockOwnItems(in: linked, userID: getuid()) == 0)
        var st = stat()
        #expect(lstat(outside.path, &st) == 0)
        #expect(st.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(TrashUnlocker.blocker(of: linked, userID: getuid()) == .protectedByMacOS)
    }

    @Test func nestedFolderWithoutReadPermissionIsUnlockedInOnePass() throws {
        let sandbox = try TestSandbox()
        let inner = try sandbox.file("home/.Trash/a/b/c.bin", bytes: 8)
        let b = inner.deletingLastPathComponent()
        let a = b.deletingLastPathComponent()
        defer { restore(b, a) }
        #expect(chmod(b.path, 0o300) == 0)
        #expect(chmod(a.path, 0o500) == 0)
        TrashUnlocker.unlockOwnItems(in: a, userID: getuid())
        try fm.removeItem(at: a)
    }

    @Test func foreignFolderInsideWritableFolderCountsOnce() throws {
        let sandbox = try TestSandbox()
        let dir = try sandbox.directory("home/.Trash/pkg/Contents")
        try sandbox.file("home/.Trash/pkg/Contents/f", bytes: 8)
        defer { restore(dir) }
        #expect(chmod(dir.path, 0o555) == 0)
        let other = getuid() &+ 1
        let result = TrashUnlocker.blocker(
            of: sandbox.root.appending(path: "home/.Trash/pkg"), userID: getuid(),
            owner: { $0.lastPathComponent == "Contents" ? other : getuid() })
        #expect(result == .otherOwner(count: 1))
    }
}
