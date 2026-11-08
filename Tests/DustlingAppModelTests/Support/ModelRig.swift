import Foundation
import DustlingCore

/// Moves items into a directory instead of the real Trash. Collisions are named like Finder.
struct DirectoryTrashBackend: TrashBackend {
    let directory: URL
    /// File names that fail to move, to exercise the `failed` outcome.
    var failingNames: Set<String> = []
    /// Holds the move of `holdName` until the gate opens, so a test can look at mid-clean state.
    var hold: (name: String, gate: Gate)?

    struct Boom: LocalizedError { var errorDescription: String? { "disk exploded" } }

    func trash(_ url: URL) throws -> URL {
        if failingNames.contains(url.lastPathComponent) { throw Boom() }
        if let hold, hold.name == url.lastPathComponent { hold.gate.wait() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var n = 1
        var target = directory.appending(path: url.lastPathComponent)
        while (try? fm.attributesOfItem(atPath: target.path(percentEncoded: false))) != nil {
            n += 1
            target = directory.appending(path: "\(url.lastPathComponent) \(n)")
        }
        try fm.moveItem(at: url, to: target)
        return target
    }
}

/// A throwaway home directory with the real macOS layout, plus the engine pieces wired to it.
/// The Trash is `home/.Trash`, so `TrashInspector` sees what the runner moved.
final class ModelRig {
    let root: URL
    let environment: SystemEnvironment
    let options = ScanOptions(includeExternalTrash: false)

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "dustling-model-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        let apps = root.appending(path: "Applications")
        let library = root.appending(path: "Library")
        let volumes = root.appending(path: "Volumes")
        for dir in [home, apps, library, volumes] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        environment = SystemEnvironment(
            home: home, applicationDirectories: [apps], systemLibrary: library,
            volumesDirectory: volumes, userID: getuid())
    }

    deinit {
        // A test may have made the Trash unreadable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: environment.userTrash.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: root)
    }

    var journal: RunJournal { RunJournal(directory: environment.historyDirectory) }
    var cachesDirectory: URL { environment.userLibrary.appending(path: "Caches", directoryHint: .isDirectory) }
    var backupsDirectory: URL {
        environment.userLibrary.appending(path: "Application Support/MobileSync/Backup", directoryHint: .isDirectory)
    }

    @discardableResult
    func file(_ url: URL, bytes: Int) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    func scanner(running: Set<String> = []) -> JunkScanner {
        JunkScanner(environment: environment, runningBundleIDs: { running })
    }

    func runner(failing: Set<String> = [], hold: (name: String, gate: Gate)? = nil) -> CleanupRunner {
        CleanupRunner(
            mover: TrashMover(
                backend: DirectoryTrashBackend(directory: environment.userTrash, failingNames: failing, hold: hold),
                protectedPaths: options.protectedPaths(environment: environment)),
            journal: journal, logger: RunLogger(directory: environment.logsDirectory), sizer: DirectorySizer())
    }

    func trashInspector() -> TrashInspector {
        TrashInspector(
            environment: environment, journal: journal, logger: RunLogger(directory: environment.logsDirectory),
            sizer: DirectorySizer(), includeExternalVolumes: false)
    }

    /// One safe category (App caches) and one review category (iPhone and iPad backups).
    func categories(cachesFilter: @escaping @Sendable (URL) -> Bool = { _ in true }) -> [JunkCategory] {
        [
            JunkCategory(
                id: .userCaches, title: "App caches", selection: .preselected, requiresAdmin: false,
                roots: [cachesDirectory], itemFilter: cachesFilter),
            JunkCategory(
                id: .iosBackups, title: "iPhone and iPad backups", selection: .review, requiresAdmin: false,
                roots: [backupsDirectory]),
        ]
    }
}

/// Blocks the scan thread the first time `wait()` is called, until the test calls `open()`.
final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var opened = false

    var hasEntered: Bool { condition.withLock { entered } }

    func wait() {
        condition.lock()
        entered = true
        while !opened { condition.wait() }
        condition.unlock()
    }

    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Polls (on the main actor, yielding) until `condition` holds; fails the wait after `seconds`.
@MainActor
func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Yields (without sleeping) until `condition` holds, up to `limit` times. Use it to catch a state
/// that holds only while main-actor work is suspended on a GCD call: a sleep could let that work
/// finish unseen, while a yield hands the main actor back before the GCD result can resume it.
@MainActor
func yieldUntil(limit: Int = 10_000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<limit {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
