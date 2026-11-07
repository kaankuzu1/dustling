import Foundation
import Testing
@testable import DustlingCore

struct ProtectedPathsTests {
    private func make() throws -> (TestSandbox, ProtectedPaths) {
        let sandbox = try TestSandbox()
        return (sandbox, ProtectedPaths(environment: sandbox.environment))
    }

    @Test func allowsChildOfAllowedRoot() throws {
        let (sb, p) = try make()
        let root = try sb.directory("home/Library/Caches")
        let item = root.appending(path: "com.x")
        #expect(p.verdict(for: item, allowedRoots: [root]) == .allowed)
    }

    @Test func deniesTheRootItself() throws {
        let (sb, p) = try make()
        let root = try sb.directory("home/Library/Caches")
        #expect(p.verdict(for: root, allowedRoots: [root]) == .denied(reason: "outside the cleanup area"))
    }

    @Test func deniesPersonalFoldersEvenInsideRoot() throws {
        let (sb, p) = try make()
        let item = try sb.file("home/Documents/a")
        #expect(p.verdict(for: item, allowedRoots: [sb.environment.home]) == .denied(reason: "protected location"))
        let lib = try sb.file("home/Library/Mail/m")
        #expect(p.verdict(for: lib, allowedRoots: [sb.environment.home]) == .denied(reason: "protected location"))
    }

    @Test func deniesSystem() throws {
        let (_, p) = try make()
        let url = URL(filePath: "/System/Library/x")
        #expect(p.verdict(for: url, allowedRoots: [URL(filePath: "/")]) == .denied(reason: "protected location"))
        #expect(p.verdict(for: URL(filePath: "/usr"), allowedRoots: [URL(filePath: "/")]) == .denied(reason: "protected location"))
    }

    @Test func deniesOtherUsersHome() throws {
        let (_, p) = try make()
        let url = URL(filePath: "/Users/someoneelse/Library/Caches/x")
        #expect(p.verdict(for: url, allowedRoots: [URL(filePath: "/Users")]) == .denied(reason: "another user's files"))
        let shared = URL(filePath: "/Users/Shared/x")
        #expect(p.verdict(for: shared, allowedRoots: [URL(filePath: "/Users")]) == .denied(reason: "another user's files"))
    }

    @Test func prefixIsNotContainment() throws {
        let (sb, p) = try make()
        let root = try sb.directory("home/Library/Caches")
        let sibling = try sb.file("home/Library/CachesX/a")
        #expect(p.verdict(for: sibling, allowedRoots: [root]) == .denied(reason: "outside the cleanup area"))
    }

    @Test func symlinkIntoProtectedFolderIsJudgedByLinkLocation() throws {
        let (sb, p) = try make()
        let root = try sb.directory("home/Library/Caches")
        let docs = try sb.directory("home/Documents")
        try sb.file("home/Documents/secret.txt")
        let link = root.appending(path: "evil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: docs)
        #expect(p.verdict(for: link, allowedRoots: [root]) == .allowed)
        #expect(p.verdict(for: link.appending(path: "secret.txt"), allowedRoots: [root])
            == .denied(reason: "protected location"))
    }

    @Test func dotDotEscapeIsDenied() throws {
        let (sb, p) = try make()
        let root = try sb.directory("home/Library/Caches")
        try sb.directory("home/Documents")
        let url = URL(filePath: root.path + "/../../Documents/x")
        if case .allowed = p.verdict(for: url, allowedRoots: [root]) { Issue.record("escaped") }
    }
}
