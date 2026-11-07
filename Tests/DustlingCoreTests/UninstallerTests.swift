import Foundation
import Testing
@testable import DustlingCore

struct UninstallerTests {
    struct FakeRunning: RunningAppsProviding {
        var running: Bool
        func isRunning(_ app: InstalledApp) -> Bool { running }
    }

    struct LaunchError: LocalizedError {
        var errorDescription: String? { "launchctl missing" }
    }

    /// Ordered log shared by the command runner and the onItem callback.
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    struct LoggingRunner: CommandRunning {
        let inner: FakeCommandRunner
        let log: EventLog
        func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
            log.add("cmd:" + arguments.joined(separator: " "))
            return try inner.run(executable, arguments)
        }
    }

    private func makeUninstaller(
        _ sandbox: TestSandbox, commands: CommandRunning, running: Bool = false
    ) -> Uninstaller {
        let backend = DirectoryTrashBackend(directory: sandbox.root.appending(path: "trash", directoryHint: .isDirectory))
        let runner = CleanupRunner(
            mover: TrashMover(backend: backend, protectedPaths: ProtectedPaths(environment: sandbox.environment)),
            journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: sandbox.environment.logsDirectory),
            sizer: DirectorySizer())

        return Uninstaller(
            runner: runner, commands: commands, running: FakeRunning(running: running),
            environment: sandbox.environment)
    }

    private func installedApp(_ url: URL, name: String = "Foo") -> InstalledApp {
        InstalledApp(
            url: url, displayName: name, bundleID: "com.example.foo", teamID: nil,
            executableName: "App", steamAppID: nil, bytes: 0, lastUsed: nil)
    }

    private func leftover(
        _ url: URL, kind: LeftoverKind, admin: Bool = false, bytes: UInt64 = 0
    ) -> Leftover {
        Leftover(
            url: url, kind: kind, match: .exact, mayContainUserData: false,
            requiresAdmin: admin, bytes: bytes)
    }

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    @Test func runningAppThrows() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let fake = FakeCommandRunner()
        let uninstaller = makeUninstaller(sandbox, commands: fake, running: true)
        await #expect(throws: UninstallError.appIsRunning("Foo")) {
            try await uninstaller.uninstall(installedApp(appURL), leftovers: []) { _, _ in }
        }
        #expect(FileManager.default.fileExists(atPath: appURL.path))
        #expect(fake.calls.isEmpty)
    }

    @Test func appBundleIsFirstEntryAndMovedToTrash() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let cache = try sandbox.file("home/Library/Caches/com.example.foo/c.bin", bytes: 10)
        let record = try await makeUninstaller(sandbox, commands: FakeCommandRunner())
            .uninstall(installedApp(appURL), leftovers: [leftover(cache, kind: .caches)]) { _, _ in }
        #expect(record.kind == .uninstall(appName: "Foo"))
        #expect(record.entries.first?.originalPath == path(appURL))
        guard case .movedToTrash = record.entries[0].outcome else {
            Issue.record("app not trashed: \(record.entries[0].outcome)"); return
        }
        guard case .movedToTrash = record.entries[1].outcome else {
            Issue.record("cache not trashed"); return
        }
        #expect(!FileManager.default.fileExists(atPath: appURL.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(record.restorable)
    }

    @Test func bootsOutUserLaunchAgentBeforeTrashing() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        let fake = FakeCommandRunner()
        let log = EventLog()
        let uninstaller = makeUninstaller(sandbox, commands: LoggingRunner(inner: fake, log: log))
        let record = try await uninstaller.uninstall(
            installedApp(appURL), leftovers: [leftover(plist, kind: .launchAgent)]
        ) { url, _ in log.add("move:" + url.lastPathComponent) }
        #expect(fake.calls.count == 1)
        #expect(fake.calls[0].executable == "/bin/launchctl")
        #expect(fake.calls[0].arguments == ["bootout", "gui/\(sandbox.environment.userID)", path(plist)])
        let events = log.all
        let cmd = try #require(events.firstIndex { $0.hasPrefix("cmd:") })
        let move = try #require(events.firstIndex(of: "move:com.example.foo.plist"))
        #expect(cmd < move)
        #expect(record.entries.count == 2)  // success adds no extra entry
        guard case .movedToTrash = record.entries[1].outcome else {
            Issue.record("plist not trashed"); return
        }
    }

    @Test func failedBootoutIsRecordedAndPlistStillTrashed() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        let fake = FakeCommandRunner()
        fake.setDefault(CommandResult(status: 5, stdout: "", stderr: "  Input/output error \n"))
        let record = try await makeUninstaller(sandbox, commands: fake)
            .uninstall(installedApp(appURL), leftovers: [leftover(plist, kind: .launchAgent)]) { _, _ in }
        #expect(record.entries.count == 3)
        #expect(record.entries[2].originalPath == path(plist))
        #expect(record.entries[2].bytes == 0)
        #expect(record.entries[2].outcome == .failed(reason: "could not unload: Input/output error"))
        guard case .movedToTrash = record.entries[1].outcome else {
            Issue.record("plist not trashed"); return
        }
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }

    @Test func notLoadedServiceIsNotAFailure() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        for stderr in ["Boot-out failed: 3: No such process", "Could not find specified service"] {
            let fake = FakeCommandRunner()
            fake.setDefault(CommandResult(status: 3, stdout: "", stderr: stderr))
            let record = try await makeUninstaller(sandbox, commands: fake)
                .uninstall(installedApp(appURL), leftovers: [leftover(plist, kind: .launchAgent)]) { _, _ in }
            #expect(record.entries.allSatisfy { if case .failed = $0.outcome { false } else { true } })
            // Recreate for the next iteration.
            _ = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
            _ = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        }
    }

    @Test func throwingBootoutIsRecorded() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        let fake = FakeCommandRunner()
        fake.setDefaultError(LaunchError())
        let record = try await makeUninstaller(sandbox, commands: fake)
            .uninstall(installedApp(appURL), leftovers: [leftover(plist, kind: .launchAgent)]) { _, _ in }
        #expect(record.entries.last?.outcome == .failed(reason: "could not unload: launchctl missing"))
        #expect(record.entries.last?.originalPath == path(plist))
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }

    @Test func adminLeftoversAreNeedsAdmin() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let daemon = try sandbox.file("Library/LaunchDaemons/com.example.foo.plist")
        let helper = try sandbox.file("Library/PrivilegedHelperTools/com.example.foo.helper")
        let adminAgent = try sandbox.file("Library/LaunchAgents/com.example.foo.plist")
        let fake = FakeCommandRunner()
        let record = try await makeUninstaller(sandbox, commands: fake).uninstall(
            installedApp(appURL),
            leftovers: [
                leftover(daemon, kind: .launchDaemon, admin: true, bytes: 111),
                leftover(helper, kind: .privilegedHelper, admin: true, bytes: 222),
                leftover(adminAgent, kind: .launchAgent, admin: true, bytes: 333),
            ]
        ) { _, _ in }
        #expect(fake.calls.isEmpty)  // admin agents are not booted out
        #expect(record.entries.count == 4)
        let admin = Array(record.entries.dropFirst())
        #expect(admin.map(\.originalPath) == [path(daemon), path(helper), path(adminAgent)])
        #expect(admin.map(\.bytes) == [111, 222, 333])
        #expect(admin.allSatisfy { $0.outcome == .needsAdmin })
        #expect(FileManager.default.fileExists(atPath: daemon.path))
        #expect(FileManager.default.fileExists(atPath: helper.path))
    }

    @Test func unloadFailuresPrecedeNeedsAdminEntries() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        let daemon = try sandbox.file("Library/LaunchDaemons/com.example.foo.plist")
        let fake = FakeCommandRunner()
        fake.setDefault(CommandResult(status: 1, stdout: "", stderr: "nope"))
        let record = try await makeUninstaller(sandbox, commands: fake).uninstall(
            installedApp(appURL),
            leftovers: [
                leftover(daemon, kind: .launchDaemon, admin: true, bytes: 9),
                leftover(plist, kind: .launchAgent),
            ]
        ) { _, _ in }
        // app, plist (runner entries), then unload failure, then needsAdmin
        #expect(record.entries.count == 4)
        #expect(record.entries[2].outcome == .failed(reason: "could not unload: nope"))
        #expect(record.entries[3].outcome == .needsAdmin)
    }
}
