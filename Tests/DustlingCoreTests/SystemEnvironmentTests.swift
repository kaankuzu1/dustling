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

    @Test func sandboxIsIsolated() throws {
        let sandbox = try TestSandbox()
        #expect(sandbox.environment.home.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
