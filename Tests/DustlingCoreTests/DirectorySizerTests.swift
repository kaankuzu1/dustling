import Foundation
import Testing
@testable import DustlingCore

struct DirectorySizerTests {
    @Test func sumsAllocatedSizes() throws {
        let sb = try TestSandbox()
        try sb.file("d/a.bin", bytes: 10_000)
        try sb.file("d/sub/b.bin", bytes: 10_000)
        let r = DirectorySizer().measure(sb.root.appending(path: "d", directoryHint: .isDirectory))
        #expect(r.bytes >= 20_000)
        #expect(r.fileCount == 2)
        #expect(r.unreadable.isEmpty)
    }

    @Test func doesNotFollowSymlinks() throws {
        let sb = try TestSandbox()
        let big = try sb.file("outside/big.bin", bytes: 1_000_000)
        let dir = try sb.directory("measured")
        try FileManager.default.createSymbolicLink(
            at: dir.appending(path: "link"), withDestinationURL: big)
        let r = DirectorySizer().measure(dir)
        #expect(r.bytes < 4096)
    }

    @Test func topLevelSymlinkMeasuresZero() throws {
        let sb = try TestSandbox()
        let big = try sb.file("outside/big.bin", bytes: 1_000_000)
        let link = sb.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
        let r = DirectorySizer().measure(link)
        #expect(r.bytes == 0)
        #expect(r.fileCount == 0)
    }

    @Test func reportsUnreadableSubfolder() throws {
        let sb = try TestSandbox()
        try sb.file("d/ok.bin", bytes: 5_000)
        let locked = try sb.directory("d/locked")
        try sb.file("d/locked/hidden.bin", bytes: 5_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        let r = DirectorySizer().measure(sb.root.appending(path: "d", directoryHint: .isDirectory))
        #expect(r.unreadable.contains { $0.lastPathComponent == "locked" })
        #expect(r.fileCount == 1)
    }

    @Test func measuresSingleFile() throws {
        let sb = try TestSandbox()
        let f = try sb.file("one.bin", bytes: 10_000)
        let r = DirectorySizer().measure(f)
        #expect(r.bytes >= 10_000)
        #expect(r.fileCount == 1)
    }

    @Test func missingPathIsReportedUnreadable() throws {
        let sb = try TestSandbox()
        let missing = sb.root.appending(path: "nope")
        let r = DirectorySizer().measure(missing)
        #expect(r.bytes == 0)
        #expect(r.fileCount == 0)
        #expect(r.unreadable == [missing])
    }

    @Test func doesNotFollowMidTreeDirectorySymlink() throws {
        let sb = try TestSandbox()
        try sb.file("outside/big.bin", bytes: 1_000_000)
        let outside = sb.root.appending(path: "outside", directoryHint: .isDirectory)
        let dir = try sb.directory("measured")
        try FileManager.default.createSymbolicLink(
            at: dir.appending(path: "evil"), withDestinationURL: outside)
        let r = DirectorySizer().measure(dir)
        #expect(r.bytes < 4096)
        #expect(r.fileCount == 0)
    }

    @Test func topLevelDirectorySymlinkMeasuresZero() throws {
        let sb = try TestSandbox()
        try sb.file("outside/big.bin", bytes: 1_000_000)
        let outside = sb.root.appending(path: "outside", directoryHint: .isDirectory)
        let link = sb.root.appending(path: "dirlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let r = DirectorySizer().measure(link)
        #expect(r.bytes == 0)
        #expect(r.fileCount == 0)
    }
}
