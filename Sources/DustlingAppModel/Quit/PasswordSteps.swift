import DustlingCore
import Foundation

/// Counts the password steps running now, so Quit can say Dustling is waiting for the Mac password
/// (`BusyWork.passwordStep`). Each step is one `AdminShell.run`: the macOS password box, then the
/// script as root. Safe from any thread.
public final class PasswordSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0

    public init() {}

    public var isRunning: Bool { lock.withLock { running > 0 } }

    fileprivate func begin() { lock.withLock { running += 1 } }
    fileprivate func end() { lock.withLock { running -= 1 } }
}

/// An `AdminShell` that tells `steps` while each of its password steps runs.
public struct WatchedAdminShell: AdminShell {
    private let shell: any AdminShell
    private let steps: PasswordSteps

    public init(_ shell: any AdminShell, steps: PasswordSteps) {
        self.shell = shell
        self.steps = steps
    }

    public func run(script: String, prompt: String) -> AdminShellResult {
        steps.begin()
        defer { steps.end() }
        return shell.run(script: script, prompt: prompt)
    }
}
