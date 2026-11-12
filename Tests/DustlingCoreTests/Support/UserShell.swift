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
