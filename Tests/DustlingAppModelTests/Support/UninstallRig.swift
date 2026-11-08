import Foundation
import DustlingCore
@testable import DustlingAppModel

/// Never spawns a process. `pkgutil` finds no receipts; launchctl calls succeed and are recorded.
final class FakeCommands: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.withLock { recorded } }
    /// Holds every `pkgutil` call (made while finding leftovers) until opened.
    var pkgutilGate: Gate?
    /// When set, only `pkgutil` calls whose arguments mention this text are held.
    var gateOnly: String?

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        lock.withLock { recorded.append([executable] + arguments) }
        if executable.hasSuffix("pkgutil"), gateOnly.map({ name in arguments.contains { $0.contains(name) } }) ?? true {
            pkgutilGate?.wait()
        }
        return CommandResult(status: executable.hasSuffix("pkgutil") ? 1 : 0, stdout: "", stderr: "")
    }
}

final class FakeRunning: RunningAppsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func set(_ app: URL, running: Bool) {
        lock.withLock { if running { paths.insert(Self.key(app)) } else { paths.remove(Self.key(app)) } }
    }

    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    func isRunning(_ app: InstalledApp) -> Bool { lock.withLock { paths.contains(Self.key(app.url)) } }
}

/// `quits` decides per app whether asking it to quit works; `hangs` never answers (until cancelled).
final class FakeQuitter: AppQuitter, @unchecked Sendable {
    let running: FakeRunning
    var quits: Set<String> = []
    var hangs: Set<String> = []
    private let lock = NSLock()
    private var asked: [String] = []
    var askedNames: [String] { lock.withLock { asked } }

    init(running: FakeRunning) { self.running = running }

    func quit(_ app: InstalledApp) async -> Bool {
        lock.withLock { asked.append(app.displayName) }
        if hangs.contains(app.displayName) {
            try? await Task.sleep(for: .seconds(1000))
            return false
        }
        if quits.contains(app.displayName) {
            running.set(app.url, running: false)
            return true
        }
        return false
    }
}

extension ModelRig {
    var applicationsDirectory: URL { environment.applicationDirectories[0] }

    @discardableResult
    func makeApp(_ name: String, bundleID: String?, in directory: URL? = nil, executable: String? = nil) throws -> URL {
        let url = (directory ?? applicationsDirectory).appending(path: "\(name).app", directoryHint: .isDirectory)
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleName": name]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let executable { info["CFBundleExecutable"] = executable }
        try (info as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        try file(contents.appending(path: "Resources/data.bin"), bytes: 2048)
        return url
    }

    @MainActor
    func uninstallerModel(
        running: FakeRunning = FakeRunning(), commands: FakeCommands = FakeCommands(),
        protectedPaths: ProtectedPaths? = nil, quitTimeout: Duration = .seconds(10),
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) -> UninstallerModel {
        let runner = runner()
        let model = UninstallerModel(
            scout: AppScout(environment: environment),
            finder: LeftoverFinder(environment: environment, sizer: DirectorySizer(), commands: commands),
            uninstaller: Uninstaller(runner: runner, commands: commands, running: running, environment: environment),
            running: running, protectedPaths: protectedPaths ?? runner.protectedPaths, journal: journal,
            logger: RunLogger(directory: environment.logsDirectory), quitTimeout: quitTimeout,
            onRunCompleted: onRunCompleted)
        // Tests run as if Full Disk Access were on; the default (off) is tested on its own.
        model.canReadAppData = true
        return model
    }

    func startupScanner(commands: FakeCommands = FakeCommands()) -> StartupItemScanner {
        StartupItemScanner(environment: environment, commands: commands, apps: [])
    }

    @discardableResult
    func writeLaunchPlist(_ dir: URL, label: String, program: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(label).plist")
        let dict: [String: Any] = ["Label": label, "ProgramArguments": [program]]
        try (dict as NSDictionary).write(to: url)
        return url
    }
}

/// Runs a hook while "asking" an app to quit, then lets it quit.
final class HookQuitter: AppQuitter, @unchecked Sendable {
    let running: FakeRunning
    let hook: @Sendable () async -> Void
    init(running: FakeRunning, hook: @escaping @Sendable () async -> Void) {
        self.running = running
        self.hook = hook
    }

    func quit(_ app: InstalledApp) async -> Bool {
        await hook()
        running.set(app.url, running: false)
        return true
    }
}
