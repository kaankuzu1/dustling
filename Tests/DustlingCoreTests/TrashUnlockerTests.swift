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
            owner: { $0.lastPathComponent == "a" || $0.lastPathComponent == "b" ? 503 : getuid() })
        #expect(result == .otherOwner(count: 2))
    }

    @Test func ownItemsHaveNoBlocker() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/x/y", bytes: 8)
        #expect(TrashUnlocker.blocker(of: sandbox.root.appending(path: "home/.Trash/x"), userID: getuid()) == nil)
    }
}
