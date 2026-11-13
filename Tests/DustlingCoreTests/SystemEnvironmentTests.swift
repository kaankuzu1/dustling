import Foundation
import Testing
@testable import DustlingCore

@Suite struct SystemEnvironmentTests {
    @Test func environmentPathsDeriveFromHome() {
        let env = SystemEnvironment(
            home: URL(filePath: "/tmp/h"),
            applicationDirectories: [URL(filePath: "/tmp/h/Applications")],
            systemLibrary: URL(filePath: "/tmp/Library"),
            volumesDirectory: URL(filePath: "/tmp/Volumes"),
            userID: 501
        )
        #expect(env.userLibrary.path == "/tmp/h/Library")
        #expect(env.userTrash.path == "/tmp/h/.Trash")
        #expect(env.logsDirectory.path == "/tmp/h/Library/Logs/Dustling")
        #expect(env.historyDirectory.path == "/tmp/h/Library/Application Support/Dustling/History")
    }

    @Test func systemManagedFoldersFollowTheSystemLibrary() {
        let env = SystemEnvironment(
            home: URL(filePath: "/tmp/h"), applicationDirectories: [], systemLibrary: URL(filePath: "/tmp/Library"),
            volumesDirectory: URL(filePath: "/tmp/Volumes"), userID: 501)
        #expect(env.systemManagedFolders.map(\.path) == ["/tmp/Library/Caches", "/tmp/Library/Logs"])
        #expect(env.isSystemManaged("/tmp/Library/Caches/com.apple.iconservices.store"))
        #expect(env.isSystemManaged("/tmp/Library/Logs/DiagnosticReports/x.ips"))
        #expect(env.isSystemManaged("/tmp/library/caches/x"))   // APFS ignores case
        // Only what is inside them, and only this environment's folders.
        #expect(!env.isSystemManaged("/tmp/Library/Caches"))
        #expect(!env.isSystemManaged("/tmp/Library/CachesOld/x"))
        #expect(!env.isSystemManaged("/Library/Caches/x"))
        #expect(!env.isSystemManaged("/tmp/h/Library/Caches/x"))
        #expect(JunkCatalog.standard(env).first { $0.id == .systemCachesAndLogs }?.roots == env.systemManagedFolders)
    }

    @Test func sandboxIsIsolated() throws {
        let sandbox = try TestSandbox()
        #expect(sandbox.environment.home.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
