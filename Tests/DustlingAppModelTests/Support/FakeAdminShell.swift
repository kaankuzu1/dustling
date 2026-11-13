import Foundation
import DustlingCore

/// Stands in for the macOS password box. It records each call and answers with a canned result,
/// never running the script: nothing moves as root and the real `/Library` is never touched.
/// `okSteps` answers "done" for that many steps; otherwise every call gets `result`.
final class FakeAdminShell: AdminShell, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let result: AdminShellResult

    init(_ result: AdminShellResult) {
        self.result = result
    }

    convenience init(okSteps: Int) {
        self.init(.finished(output: (0..<okSteps).map { "R\t\($0)\tok" }.joined(separator: "\n")))
    }

    /// The prompt of every call, in order.
    var prompts: [String] { lock.withLock { recorded } }

    func run(script: String, prompt: String) -> AdminShellResult {
        lock.withLock { recorded.append(prompt) }
        return result
    }
}

extension ModelRig {
    /// An `AdminMover` for this rig's home whose password box is `shell`.
    func admin(_ shell: FakeAdminShell) -> AdminMover {
        AdminMover(shell: shell, environment: environment)
    }

    /// Makes `folder` read-only (0555) so moving out of it needs an administrator, as a system folder
    /// would. `unlockFolder` undoes it; tests call it before the rig is removed.
    func lockFolder(_ folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))
    }

    func unlockFolder(_ folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
    }
}
