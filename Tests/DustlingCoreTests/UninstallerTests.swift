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
        _ sandbox: TestSandbox, commands: CommandRunning, running: Bool = false,
        options: ScanOptions = ScanOptions()
    ) -> Uninstaller {
        let backend = DirectoryTrashBackend(directory: sandbox.root.appending(path: "trash", directoryHint: .isDirectory))
        let runner = CleanupRunner(
            mover: TrashMover(backend: backend, protectedPaths: options.protectedPaths(environment: sandbox.environment)),
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
        // A leftover is a direct child of a declared location (here the app's cache folder).
        let cache = try sandbox.file("home/Library/Caches/com.example.foo/c.bin", bytes: 10).deletingLastPathComponent()
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

    @Test func excludedLaunchAgentIsNeitherBootedOutNorTrashed() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        let fake = FakeCommandRunner()
        let uninstaller = makeUninstaller(sandbox, commands: fake, options: ScanOptions(exclusions: [plist.path]))
        let record = try await uninstaller.uninstall(
            installedApp(appURL), leftovers: [leftover(plist, kind: .launchAgent)]) { _, _ in }
        #expect(fake.calls.isEmpty)
        #expect(record.entries[1].outcome == .skipped(reason: "excluded in Settings"))
        #expect(FileManager.default.fileExists(atPath: plist.path))
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

    @Test func vagueBootoutErrorForAnAgentThatIsNotLoadedIsNotAFailure() async throws {
        // macOS 26 and later: booting out a plist that isn't loaded fails with "5: Input/output error".
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        try labelledPlist("com.example.foo").write(to: plist)
        let uid = sandbox.environment.userID
        let fake = FakeCommandRunner()
        fake.setResult(CommandResult(status: 5, stdout: "", stderr: "Boot-out failed: 5: Input/output error"),
                       for: "/bin/launchctl", ["bootout", "gui/\(uid)", path(plist)])
        fake.setResult(CommandResult(status: 113, stdout: "", stderr: "Could not find service"),
                       for: "/bin/launchctl", ["print", "gui/\(uid)/com.example.foo"])
        let record = try await makeUninstaller(sandbox, commands: fake)
            .uninstall(installedApp(appURL), leftovers: [leftover(plist, kind: .launchAgent)]) { _, _ in }
        #expect(record.entries.allSatisfy { if case .failed = $0.outcome { false } else { true } })
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }

    @Test func vagueBootoutErrorForALoadedAgentIsStillAFailure() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        try labelledPlist("com.example.foo").write(to: plist)
        let uid = sandbox.environment.userID
        let fake = FakeCommandRunner()
        fake.setResult(CommandResult(status: 5, stdout: "", stderr: "Boot-out failed: 5: Input/output error"),
                       for: "/bin/launchctl", ["bootout", "gui/\(uid)", path(plist)])
        fake.setResult(CommandResult(status: 0, stdout: "state = running", stderr: ""),
                       for: "/bin/launchctl", ["print", "gui/\(uid)/com.example.foo"])
        let record = try await makeUninstaller(sandbox, commands: fake)
            .uninstall(installedApp(appURL), leftovers: [leftover(plist, kind: .launchAgent)]) { _, _ in }
        #expect(record.entries.last?.outcome == .failed(reason: "could not unload: Boot-out failed: 5: Input/output error"))
    }

    @Test func otherPrintErrorsKeepTheBootoutFailure() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        try labelledPlist("com.example.foo").write(to: plist)
        let uid = sandbox.environment.userID
        let fake = FakeCommandRunner()
        fake.setResult(CommandResult(status: 5, stdout: "", stderr: "Boot-out failed: 5: Input/output error"),
                       for: "/bin/launchctl", ["bootout", "gui/\(uid)", path(plist)])
        fake.setResult(CommandResult(status: 64, stdout: "", stderr: "Bad request."),
                       for: "/bin/launchctl", ["print", "gui/\(uid)/com.example.foo"])
        let record = try await makeUninstaller(sandbox, commands: fake)
            .uninstall(installedApp(appURL), leftovers: [leftover(plist, kind: .launchAgent)]) { _, _ in }
        #expect(record.entries.last?.outcome == .failed(reason: "could not unload: Boot-out failed: 5: Input/output error"))
    }

    private func labelledPlist(_ label: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Label": label], format: .xml, options: 0)
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
    // MARK: - App first, fixed roots (Important #3)

    private static let kept = DeletionOutcome.skipped(reason: "kept because the app itself was not removed")

    @Test func leftoversAreKeptWhenTheAppIsNotRemoved() async throws {
        let sandbox = try TestSandbox()
        // Outside every application folder, so the app itself is refused.
        let appURL = try sandbox.app("elsewhere/Foo.app", bundleID: "com.example.foo")
        let cache = try sandbox.file("home/Library/Caches/com.example.foo/c.bin", bytes: 10)
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        let daemon = try sandbox.file("Library/LaunchDaemons/com.example.foo.plist")
        let fake = FakeCommandRunner()
        let record = try await makeUninstaller(sandbox, commands: fake).uninstall(
            installedApp(appURL),
            leftovers: [
                leftover(cache, kind: .caches, bytes: 10),
                leftover(plist, kind: .launchAgent),
                leftover(daemon, kind: .launchDaemon, admin: true),
            ]
        ) { _, _ in }
        #expect(record.entries.first?.originalPath == path(appURL))
        #expect(record.entries.first?.outcome == .skipped(reason: "outside the cleanup area"))
        #expect(record.entries.dropFirst().map(\.outcome) == [Self.kept, Self.kept, Self.kept])
        #expect(record.entries.dropFirst().map(\.originalPath) == [path(cache), path(plist), path(daemon)])
        #expect(fake.calls.isEmpty)   // no launchctl bootout
        for url in [appURL, cache, plist, daemon] { #expect(FileManager.default.fileExists(atPath: url.path)) }
        #expect(!record.restorable)
    }

    @Test func leftoversAreKeptWhenMovingTheAppFails() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let cache = try sandbox.file("home/Library/Caches/com.example.foo/c.bin")
        let backend = FailingBackend(
            inner: DirectoryTrashBackend(directory: sandbox.root.appending(path: "trash", directoryHint: .isDirectory)),
            failingName: "Foo.app")
        let runner = CleanupRunner(
            mover: TrashMover(backend: backend, protectedPaths: ProtectedPaths(environment: sandbox.environment)),
            journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: sandbox.environment.logsDirectory), sizer: DirectorySizer())
        let uninstaller = Uninstaller(
            runner: runner, commands: FakeCommandRunner(), running: FakeRunning(running: false),
            environment: sandbox.environment)
        let record = try await uninstaller.uninstall(
            installedApp(appURL), leftovers: [leftover(cache, kind: .caches)]) { _, _ in }
        guard case .failed = record.entries[0].outcome else { Issue.record("app should fail"); return }
        #expect(record.entries[1].outcome == Self.kept)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        let saved = try #require(try RunJournal(directory: sandbox.environment.historyDirectory).all().first)
        #expect(saved.entries == record.entries)
    }

    @Test func callerSkipsBecomeSkipEntriesOnlyAndNeverMove() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let container = try sandbox.file("home/Library/Containers/com.example.foo/Data/doc.bin")
        let containerDir = container.deletingLastPathComponent().deletingLastPathComponent()
        let backend = FailingBackend(
            inner: DirectoryTrashBackend(directory: sandbox.root.appending(path: "trash", directoryHint: .isDirectory)),
            failingName: "Foo.app")
        let runner = CleanupRunner(
            mover: TrashMover(backend: backend, protectedPaths: ProtectedPaths(environment: sandbox.environment)),
            journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: sandbox.environment.logsDirectory), sizer: DirectorySizer())
        let uninstaller = Uninstaller(
            runner: runner, commands: FakeCommandRunner(), running: FakeRunning(running: false),
            environment: sandbox.environment)
        let skipped = leftover(containerDir, kind: .container, bytes: 9_999)
        // The same item passed to be moved AND skipped is only skipped.
        // The same folder spelled with a trailing slash still counts as the skipped one.
        let slashed = leftover(URL(filePath: containerDir.path(percentEncoded: false) + "/"), kind: .container, bytes: 9_999)
        let record = try await uninstaller.uninstall(
            installedApp(appURL), leftovers: [slashed], skipped: [skipped], skipReason: "needs Full Disk Access"
        ) { _, _ in }

        let path = containerDir.path(percentEncoded: false)
        #expect(record.entries.filter { $0.originalPath == path }.map(\.outcome)
            == [.skipped(reason: "needs Full Disk Access")])
        // A caller can't make the record restorable or count bytes for something that didn't move.
        #expect(!record.restorable)
        #expect(record.bytesMovedToTrash == 0)
        #expect(FileManager.default.fileExists(atPath: container.path))
    }

    struct FailingBackend: TrashBackend {
        let inner: DirectoryTrashBackend
        let failingName: String
        func trash(_ url: URL) throws -> URL {
            if url.lastPathComponent == failingName { throw LaunchError() }
            return try inner.trash(url)
        }
    }

    @Test func appMovesBeforeAgentsAreUnloadedAndLeftoversMoved() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let plist = try sandbox.file("home/Library/LaunchAgents/com.example.foo.plist")
        let log = EventLog()
        _ = try await makeUninstaller(sandbox, commands: LoggingRunner(inner: FakeCommandRunner(), log: log))
            .uninstall(installedApp(appURL), leftovers: [leftover(plist, kind: .launchAgent)]) { url, _ in
                log.add("move:" + url.lastPathComponent)
            }
        #expect(log.all == ["move:Foo.app", "cmd:bootout gui/\(sandbox.environment.userID) \(path(plist))",
                            "move:com.example.foo.plist"])
    }

    @Test func foreignLeftoversAreOutsideTheCleanupArea() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let download = try sandbox.file("home/Downloads/x.bin")
        let cachesFolder = try sandbox.directory("home/Library/Caches")
        try sandbox.file("home/Library/Caches/other/keep.bin")
        let nested = try sandbox.file("home/Library/Application Support/Google/Chrome/Default/keep.db")
            .deletingLastPathComponent()
        let library = sandbox.environment.userLibrary
        let fake = FakeCommandRunner()
        let record = try await makeUninstaller(sandbox, commands: fake).uninstall(
            installedApp(appURL),
            leftovers: [
                leftover(download, kind: .caches),
                leftover(cachesFolder, kind: .caches),
                leftover(nested, kind: .applicationSupport),
                leftover(sandbox.root.appending(path: "home/Downloads/agent.plist"), kind: .launchAgent),
                leftover(library, kind: .caches),
            ]
        ) { _, _ in }
        let outside = DeletionOutcome.skipped(reason: "outside the cleanup area")
        #expect(record.entries[1].outcome == outside)
        #expect(record.entries[2].outcome == outside)
        #expect(record.entries[3].outcome == outside)
        #expect(record.entries[4].outcome == outside)
        guard case .skipped = record.entries[5].outcome else { Issue.record("~/Library must be skipped"); return }
        #expect(fake.calls.isEmpty)   // a launch agent outside ~/Library/LaunchAgents is never booted out
        for url in [download, cachesFolder, nested, library] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func steamGameDataIsInsideTheCleanupArea() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("home/Applications/Portal.app", bundleID: nil)
        let game = try sandbox.file("home/Library/Application Support/Steam/steamapps/common/Portal/p.dat")
            .deletingLastPathComponent()
        let record = try await makeUninstaller(sandbox, commands: FakeCommandRunner())
            .uninstall(installedApp(appURL), leftovers: [leftover(game, kind: .steamGameData)]) { _, _ in }
        guard case .movedToTrash = record.entries[1].outcome else {
            Issue.record("game data should move: \(record.entries[1].outcome)"); return
        }
    }
    @Test func aDeclaredLocationItselfIsNeverALeftover() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let steam = "home/Library/Application Support/Steam/steamapps"
        let common = try sandbox.file("\(steam)/common/Portal/p.dat").deletingLastPathComponent().deletingLastPathComponent()
        let steamapps = common.deletingLastPathComponent()
        let byHost = try sandbox.file("home/Library/Preferences/ByHost/com.other.X.plist").deletingLastPathComponent()
        let agents = try sandbox.file("home/Library/LaunchAgents/com.other.plist").deletingLastPathComponent()
        let fake = FakeCommandRunner()
        let record = try await makeUninstaller(sandbox, commands: fake).uninstall(
            installedApp(appURL),
            leftovers: [
                leftover(common, kind: .steamGameData),
                leftover(steamapps, kind: .steamGameData),
                leftover(byHost, kind: .preferences),
                leftover(agents, kind: .launchAgent),
            ]
        ) { _, _ in }
        guard case .movedToTrash = record.entries[0].outcome else { Issue.record("app should move"); return }
        let outside = DeletionOutcome.skipped(reason: "outside the cleanup area")
        #expect(record.entries.dropFirst().map(\.outcome) == [outside, outside, outside, outside])
        #expect(fake.calls.isEmpty)
        for url in [common, steamapps, byHost, agents] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    // MARK: - What belongs to the system: one password box per uninstall action

    /// An uninstaller whose runner moves into the sandbox's Trash (where password moves go too).
    private func adminUninstaller(
        _ sandbox: TestSandbox, admin: AdminMover?, commands: CommandRunning = FakeCommandRunner()
    ) -> Uninstaller {
        let runner = CleanupRunner(
            mover: TrashMover(backend: DirectoryTrashBackend(directory: sandbox.environment.userTrash),
                              protectedPaths: ProtectedPaths(environment: sandbox.environment)),
            journal: RunJournal(directory: sandbox.environment.historyDirectory),
            logger: RunLogger(directory: sandbox.environment.logsDirectory),
            sizer: DirectorySizer(), admin: admin)
        return Uninstaller(runner: runner, commands: commands, running: FakeRunning(running: false),
                           environment: sandbox.environment)
    }

    private func adminMover(_ shell: any AdminShell, _ sandbox: TestSandbox) throws -> AdminMover {
        AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
    }

    private func trashed(_ sandbox: TestSandbox, _ name: String) -> DeletionOutcome {
        .movedToTrash(trashedPath: path(sandbox.environment.userTrash.appending(path: name)))
    }

    private func moveLines(_ script: String?) -> [String] {
        (script ?? "").split(separator: "\n").filter { $0.hasPrefix("move_ ") }.map(String.init)
    }

    private func logText(_ sandbox: TestSandbox) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(
            at: sandbox.environment.logsDirectory, includingPropertiesForKeys: nil)
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    @Test func uninstallerMovesSystemAppAndItsLeftoversAfterPassword() async throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let helper = try sandbox.file("Library/PrivilegedHelperTools/com.example.foo.helper", bytes: 5)
        let cache = try sandbox.file("home/Library/Caches/com.example.foo/c.bin", bytes: 10).deletingLastPathComponent()
        let apps = sandbox.root.appending(path: "Applications")
        let tools = helper.deletingLastPathComponent()
        FolderMode.lock(apps)
        FolderMode.lock(tools)
        defer { FolderMode.unlock(apps); FolderMode.unlock(tools) }
        let shell = UserShell(beforeRun: { FolderMode.unlock(apps); FolderMode.unlock(tools) })
        let uninstaller = adminUninstaller(sandbox, admin: try adminMover(shell, sandbox))
        let app = installedApp(appURL)
        let leftovers = [leftover(helper, kind: .privilegedHelper, admin: true, bytes: 5),
                         leftover(cache, kind: .caches, bytes: 10)]

        let first = try await uninstaller.uninstall(app, leftovers: leftovers) { _, _ in }
        #expect(first.entries.map(\.outcome) == [.needsAdmin, Self.kept, Self.kept])
        #expect(shell.calls.isEmpty)

        let records = await uninstaller.moveSystemItems([first], jobs: [UninstallJob(app: app, leftovers: leftovers)])
        #expect(shell.calls.count == 1)
        #expect(shell.calls.first?.prompt == AdminMover.movePrompt(count: 2))
        // The script moves the app, then the helper only if the app moved; the cache is not in it.
        let lines = moveLines(shell.calls.first?.script)
        #expect(lines.count == 2)
        #expect(lines.last?.hasPrefix("move_ 1 0 0 ") == true)
        let record = try #require(records.first)
        #expect(records.count == 1 && record.id == first.id)
        // Replaced in place: the app, the helper (by the script) and the cache (the normal way, after).
        #expect(record.entries.map(\.originalPath) == first.entries.map(\.originalPath))
        #expect(record.entries.map(\.outcome)
            == [trashed(sandbox, "Foo.app"), trashed(sandbox, "com.example.foo.helper"), trashed(sandbox, "com.example.foo")])
        #expect(record.entries[0].trashedIdentity?.owner == getuid())
        #expect(record.entries[0].trashedIdentity == TrashedIdentity.of(path: path(sandbox.environment.userTrash.appending(path: "Foo.app"))))
        #expect(record.restorable)
        for url in [appURL, helper, cache] { #expect(!FileManager.default.fileExists(atPath: path(url))) }
        let saved = try RunJournal(directory: sandbox.environment.historyDirectory).all()
        #expect(saved.count == 1)
        #expect(saved.first?.id == first.id && saved.first?.entries == record.entries && saved.first?.restorable == true)
        let text = try logText(sandbox)
        #expect(text.contains("\(path(appURL)) -> \(path(sandbox.environment.userTrash.appending(path: "Foo.app")))"))
        #expect(text.hasSuffix("  total: moved \(ByteCountFormatter.string(fromByteCount: Int64(record.bytesMovedToTrash), countStyle: .file)) to Trash, 0 failed, 0 need admin, 0 skipped\n"))
    }

    @Test func uninstallerKeepsLeftoversWhenSystemAppStays() async throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let helper = try sandbox.file("Library/PrivilegedHelperTools/com.example.foo.helper", bytes: 5)
        let cache = try sandbox.file("home/Library/Caches/com.example.foo/c.bin", bytes: 10).deletingLastPathComponent()
        let apps = sandbox.root.appending(path: "Applications")
        FolderMode.lock(apps)
        defer { FolderMode.unlock(apps) }
        let shell = CannedShell(.cancelled)
        let uninstaller = adminUninstaller(sandbox, admin: try adminMover(shell, sandbox))
        let app = installedApp(appURL)
        let leftovers = [leftover(helper, kind: .privilegedHelper, admin: true), leftover(cache, kind: .caches)]
        let first = try await uninstaller.uninstall(app, leftovers: leftovers) { _, _ in }
        let records = await uninstaller.moveSystemItems([first], jobs: [UninstallJob(app: app, leftovers: leftovers)])
        #expect(shell.calls.count == 1)
        #expect(records.first?.entries.map(\.outcome) == [.needsAdmin, Self.kept, Self.kept])
        #expect(records.first?.restorable == false)
        for url in [appURL, helper, cache] { #expect(FileManager.default.fileExists(atPath: path(url))) }
        #expect(try RunJournal(directory: sandbox.environment.historyDirectory).all().first?.entries == first.entries)
    }

    @Test func uninstallerBatchesSeveralAppsIntoOnePrompt() async throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let foo = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let bar = try sandbox.app("Applications/Bar.app", bundleID: "com.example.bar")
        let apps = sandbox.root.appending(path: "Applications")
        FolderMode.lock(apps)
        defer { FolderMode.unlock(apps) }
        let shell = UserShell(beforeRun: { FolderMode.unlock(apps) })
        let uninstaller = adminUninstaller(sandbox, admin: try adminMover(shell, sandbox))
        let jobs = [UninstallJob(app: installedApp(foo), leftovers: []),
                    UninstallJob(app: installedApp(bar, name: "Bar"), leftovers: [])]
        var records: [RunRecord] = []
        for job in jobs { records.append(try await uninstaller.uninstall(job.app, leftovers: []) { _, _ in }) }
        #expect(records.map { $0.entries.map(\.outcome) } == [[.needsAdmin], [.needsAdmin]])
        let moved = await uninstaller.moveSystemItems(records, jobs: jobs)
        #expect(shell.calls.count == 1)
        #expect(shell.calls.first?.prompt == AdminMover.movePrompt(count: 2))
        #expect(moved.map(\.id) == records.map(\.id))
        #expect(moved.map { $0.entries.map(\.outcome) } == [[trashed(sandbox, "Foo.app")], [trashed(sandbox, "Bar.app")]])
        #expect(moved.allSatisfy { $0.restorable })
    }

    @Test func uninstallerMovesSystemLeftoversOfAnAppThatMoved() async throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let appURL = try sandbox.app("home/Applications/Foo.app", bundleID: "com.example.foo")
        let helper = try sandbox.file("Library/PrivilegedHelperTools/com.example.foo.helper", bytes: 5)
        // Not a direct child of a declared location: never in the script, whatever the finder said.
        let stray = try sandbox.file("Library/Elsewhere/com.example.foo", bytes: 5)
        let tools = helper.deletingLastPathComponent()
        FolderMode.lock(tools)
        defer { FolderMode.unlock(tools) }
        let shell = UserShell(beforeRun: { FolderMode.unlock(tools) })
        let uninstaller = adminUninstaller(sandbox, admin: try adminMover(shell, sandbox))
        let app = installedApp(appURL)
        let leftovers = [leftover(helper, kind: .privilegedHelper, admin: true),
                         leftover(stray, kind: .privilegedHelper, admin: true)]
        let first = try await uninstaller.uninstall(app, leftovers: leftovers) { _, _ in }
        #expect(first.entries.map(\.outcome) == [trashed(sandbox, "Foo.app"), .needsAdmin, .needsAdmin])
        let records = await uninstaller.moveSystemItems([first], jobs: [UninstallJob(app: app, leftovers: leftovers)])
        #expect(shell.calls.count == 1)
        #expect(shell.calls.first?.prompt == AdminMover.movePrompt(count: 1))
        #expect(moveLines(shell.calls.first?.script).count == 1)
        #expect(records.first?.entries.map(\.outcome) == [
            trashed(sandbox, "Foo.app"), trashed(sandbox, "com.example.foo.helper"),
            .skipped(reason: "outside the cleanup area"),
        ])
        #expect(FileManager.default.fileExists(atPath: path(stray)))
    }

    @Test func systemDaemonIsStoppedByTheScriptBeforeItMoves() async throws {
        // Only the script's text is checked: launchctl never runs in a test.
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let appURL = try sandbox.app("home/Applications/Foo.app", bundleID: "com.example.foo")
        let daemon = try sandbox.file("Library/LaunchDaemons/com.example.foo.plist")
        let shell = CannedShell(.cancelled)
        let uninstaller = adminUninstaller(sandbox, admin: try adminMover(shell, sandbox))
        let app = installedApp(appURL)
        let leftovers = [leftover(daemon, kind: .launchDaemon, admin: true)]
        let first = try await uninstaller.uninstall(app, leftovers: leftovers) { _, _ in }
        let records = await uninstaller.moveSystemItems([first], jobs: [UninstallJob(app: app, leftovers: leftovers)])
        // move_ <index> <head> <bootout> …: no head, bootout on.
        let lines = moveLines(shell.calls.first?.script)
        #expect(lines.count == 1 && lines.first?.hasPrefix("move_ 0 - 1 ") == true)
        #expect(records.first?.entries.last?.outcome == .needsAdmin)
        #expect(FileManager.default.fileExists(atPath: path(daemon)))
    }

    @Test func uninstallerWithoutAdminReturnsRecordsUnchanged() async throws {
        let sandbox = try TestSandbox()
        let appURL = try sandbox.app("Applications/Foo.app", bundleID: "com.example.foo")
        let apps = sandbox.root.appending(path: "Applications")
        FolderMode.lock(apps)
        defer { FolderMode.unlock(apps) }
        let uninstaller = adminUninstaller(sandbox, admin: nil)
        let app = installedApp(appURL)
        let first = try await uninstaller.uninstall(app, leftovers: []) { _, _ in }
        let records = await uninstaller.moveSystemItems([first], jobs: [UninstallJob(app: app, leftovers: [])])
        #expect(records == [first])
        #expect(FileManager.default.fileExists(atPath: path(appURL)))
    }
}
