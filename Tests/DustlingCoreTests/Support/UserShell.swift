import Foundation
@testable import DustlingCore

/// An `AdminShell` that runs the script as the current user with `/bin/sh -c`: no password box,
/// no root. The environment is emptied and HOME points at the read-only `/var/empty`, so even a
/// quoting bug that let a name like `;rm -rf ~` run could never reach the real home folder.
/// Every call is recorded. `beforeRun` runs after the script was made (planned) and before it
/// runs, to change the sandbox the way another program could in between.
final class UserShell: AdminShell, @unchecked Sendable {
    struct Call: Equatable {
        let script: String
        let prompt: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let beforeRun: @Sendable () throws -> Void

    init(beforeRun: @escaping @Sendable () throws -> Void = {}) {
        self.beforeRun = beforeRun
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func run(script: String, prompt: String) -> AdminShellResult {
        lock.lock()
        _calls.append(Call(script: script, prompt: prompt))
        lock.unlock()
        // Only the sandbox: a test script must never even try to make its bridge in the real /Library.
        if script.contains("\nbridge_ '/Library'") {
            return .failed(reason: "a test script must make its bridge in its sandbox")
        }
        do {
            try beforeRun()
            let result = try ProcessCommandRunner().run(
                "/bin/sh", ["-c", script], environment: ["HOME": "/var/empty"])
            return result.status == 0
                ? .finished(output: result.stdout)
                : .failed(reason: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failed(reason: "\(error)")
        }
    }
}

extension TestSandbox {
    /// The sandbox's folders outside `home` count as root-only chains, like `/Library`; the ones in
    /// `home`, like `~/.Trash`, don't; nothing outside the sandbox does.
    var rootOnlyOutsideHome: @Sendable (String) -> Bool {
        let root = self.root.path(percentEncoded: false)
        let home = environment.home.path(percentEncoded: false)
        return { path in
            (path == root || path.hasPrefix(root + "/")) && path != home && !path.hasPrefix(home + "/")
        }
    }
}

/// An `AdminShell` that never runs anything and always answers `result` (by default the user
/// cancelled the password box). Every call is recorded.
final class CannedShell: AdminShell, @unchecked Sendable {
    private let result: AdminShellResult
    private let lock = NSLock()
    private var _calls: [UserShell.Call] = []

    init(_ result: AdminShellResult = .cancelled) {
        self.result = result
    }

    var calls: [UserShell.Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func run(script: String, prompt: String) -> AdminShellResult {
        lock.lock(); defer { lock.unlock() }
        _calls.append(UserShell.Call(script: script, prompt: prompt))
        return result
    }
}

extension TestSandbox {
    /// Where test scripts make their bridge, instead of `/Library`.
    var bridges: URL { root.appending(path: "bridges") }

    /// Planning for admin scripts run as the user (a test can't make root-owned folders): the
    /// bridge is made in `bridges` and must be owned by the user running the test; folder chains
    /// outside `home` count as root-only (`rootOnlyOutsideHome`, for the bridge's parent and for
    /// bootout); whether the user can write a folder is the real answer unless `locked` says so;
    /// the sandbox's `home/.Trash` (and `Volumes/<volume>/.Trashes/<uid>`) are the Trash.
    func adminPlanning(bridgeOwner: uid_t = getuid(), locked: @escaping @Sendable (String) -> Bool = { _ in false })
        throws -> AdminPlanning
    {
        try FileManager.default.createDirectory(at: bridges, withIntermediateDirectories: true)
        return AdminPlanning(
            bridgeParent: bridges.path(percentEncoded: false), bridgeOwner: bridgeOwner,
            rootOnlyChain: rootOnlyOutsideHome, locked: locked, isTrash: AdminPlanning.trash(of: environment))
    }
}
