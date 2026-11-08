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

    @Test func caseVariantsOfProtectedNamesAreDenied() throws {
        let (sb, p) = try make()
        let home = sb.environment.home
        let denied = PathVerdict.denied(reason: "protected location")
        #expect(p.verdict(for: home.appending(path: "documents"), allowedRoots: [home]) == denied)
        #expect(p.verdict(for: home.appending(path: "Documentſ"), allowedRoots: [home]) == denied)
        #expect(p.verdict(for: home.appending(path: "Library/mail"), allowedRoots: [home.appending(path: "Library")]) == denied)
        #expect(p.verdict(for: URL(filePath: "/system"), allowedRoots: [URL(filePath: "/")]) == denied)
        #expect(p.verdict(for: URL(filePath: "/USR"), allowedRoots: [URL(filePath: "/")]) == denied)
        #expect(p.verdict(for: URL(filePath: "/private/var/DB"), allowedRoots: [URL(filePath: "/")]) == denied)
    }

    @Test func symlinkedHomeKeepsHomeEntriesProtected() throws {
        let sb = try TestSandbox()
        try sb.directory("realhome/Library")
        let linkHome = sb.root.appending(path: "linkhome")
        try FileManager.default.createSymbolicLink(
            at: linkHome, withDestinationURL: sb.root.appending(path: "realhome"))
        var env = sb.environment
        env.home = linkHome
        let p = ProtectedPaths(environment: env)
        let roots = [linkHome.appending(path: "Library")]
        let denied = PathVerdict.denied(reason: "protected location")
        #expect(p.verdict(for: linkHome.appending(path: "Library/Mail"), allowedRoots: roots) == denied)
        #expect(p.verdict(for: linkHome.appending(path: "Library/Keychains/x"), allowedRoots: roots) == denied)
        #expect(p.verdict(for: linkHome.appending(path: "Library/Caches/x"), allowedRoots: roots) == .allowed)
    }

    @Test func symlinkedDeniedFolderIsProtectedAtItsRealLocation() throws {
        let sb = try TestSandbox()
        let elsewhere = try sb.directory("elsewhere")
        try sb.file("elsewhere/f")
        try FileManager.default.createSymbolicLink(
            at: sb.environment.home.appending(path: "Documents"), withDestinationURL: elsewhere)
        let p = ProtectedPaths(environment: sb.environment)
        #expect(p.verdict(for: elsewhere.appending(path: "f"), allowedRoots: [sb.root])
            == .denied(reason: "protected location"))
    }

    @Test func ownHomeVersusOtherUsersUnderUsers() throws {
        let sb = try TestSandbox()
        var env = sb.environment
        env.home = URL(filePath: "/Users/alice")
        let p = ProtectedPaths(environment: env)
        let caches = URL(filePath: "/Users/alice/Library/Caches")
        #expect(p.verdict(for: caches.appending(path: "x"), allowedRoots: [caches]) == .allowed)
        #expect(p.verdict(for: URL(filePath: "/Users/aliceX/Library/Caches/x"), allowedRoots: [URL(filePath: "/Users")])
            == .denied(reason: "another user's files"))
        #expect(p.verdict(for: URL(filePath: "/Users/ALICE/Library/Caches/x"), allowedRoots: [caches]) == .allowed)
    }

    @Test func diacriticAndWidthVariantsAreNotOwnHomeOrInsideRoot() throws {
        let sb = try TestSandbox()
        var env = sb.environment
        env.home = URL(filePath: "/Users/alice")
        let p = ProtectedPaths(environment: env)
        let other = PathVerdict.denied(reason: "another user's files")
        #expect(p.verdict(for: URL(filePath: "/Users/alicé/Library/Caches/x"),
                          allowedRoots: [URL(filePath: "/Users/alice/Library/Caches")]) == other)
        #expect(p.verdict(for: URL(filePath: "/Users/alicé/Library/Caches/x"),
                          allowedRoots: [URL(filePath: "/Users")]) == other)
        #expect(p.verdict(for: URL(filePath: "/Users/ａlice/x"), allowedRoots: [URL(filePath: "/Users")]) == other)

        let q = ProtectedPaths(environment: sb.environment)
        let caches = try sb.directory("home/Library/Caches")
        try sb.directory("home/Library/Cachés")
        #expect(q.verdict(for: sb.root.appending(path: "home/Library/Cachés/x"), allowedRoots: [caches])
            == .denied(reason: "outside the cleanup area"))
    }
    // MARK: - Home and ~/Library themselves (T2), CloudStorage (Minor 4)

    @Test func homeFolderItselfIsDenied() throws {
        let (sb, p) = try make()
        let home = sb.environment.home
        let denied = PathVerdict.denied(reason: "protected location")
        #expect(p.verdict(for: home, allowedRoots: [home.deletingLastPathComponent()]) == denied)
        #expect(p.verdict(for: home, allowedRoots: [URL(filePath: "/")]) == denied)
        #expect(p.verdict(for: home.appending(path: "/"), allowedRoots: [sb.root]) == denied)
    }

    @Test func libraryFolderItselfIsDenied() throws {
        let (sb, p) = try make()
        let home = sb.environment.home
        try sb.directory("home/Library")
        let denied = PathVerdict.denied(reason: "protected location")
        #expect(p.verdict(for: home.appending(path: "Library"), allowedRoots: [home]) == denied)
        #expect(p.verdict(for: home.appending(path: "library"), allowedRoots: [home]) == denied)
    }

    @Test func homeAndLibraryAreDeniedByEqualityOnly() throws {
        let (sb, p) = try make()
        let home = sb.environment.home
        try sb.directory("home/Downloads")
        try sb.directory("home/Library/Caches")
        #expect(p.verdict(for: home.appending(path: "Downloads/x"), allowedRoots: [home]) == .allowed)
        #expect(p.verdict(for: home.appending(path: "Library/Caches"), allowedRoots: [home.appending(path: "Library")])
            == .allowed)
    }

    @Test func ownHomeUnderUsersIsDeniedItself() throws {
        let sb = try TestSandbox()
        var env = sb.environment
        env.home = URL(filePath: "/Users/alice")
        let p = ProtectedPaths(environment: env)
        #expect(p.verdict(for: URL(filePath: "/Users/alice"), allowedRoots: [URL(filePath: "/Users")])
            == .denied(reason: "protected location"))
        #expect(p.verdict(for: URL(filePath: "/Users/alice/Library"), allowedRoots: [URL(filePath: "/Users/alice")])
            == .denied(reason: "protected location"))
    }

    @Test func cloudStorageIsDenied() throws {
        let (sb, p) = try make()
        let lib = sb.environment.home.appending(path: "Library")
        try sb.file("home/Library/CloudStorage/OneDrive-Personal/report.docx")
        let denied = PathVerdict.denied(reason: "protected location")
        #expect(p.verdict(for: lib.appending(path: "CloudStorage"), allowedRoots: [lib]) == denied)
        #expect(p.verdict(for: lib.appending(path: "CloudStorage/OneDrive-Personal"), allowedRoots: [lib]) == denied)
        #expect(p.verdict(for: lib.appending(path: "CloudStorage/OneDrive-Personal/report.docx"),
                          allowedRoots: [lib.appending(path: "CloudStorage")]) == denied)
    }
}

