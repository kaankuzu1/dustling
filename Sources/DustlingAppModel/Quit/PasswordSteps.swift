import DustlingCore
import Foundation

/// Counts the password steps running now, so the screens can say Dustling is waiting for the Mac
/// password and Quit can name it (`BusyWork.passwordStep`). Each step is one `AdminShell.run`: the
/// macOS password box, then the script as root. Safe from any thread.
public final class PasswordSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var changed: (@Sendable () -> Void)?

    public init() {}

    public var isRunning: Bool { lock.withLock { running > 0 } }

    /// Called on the step's own thread each time a step starts or ends; read `isRunning` in it (or
    /// later) for the state now.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changed } }
        set { lock.withLock { changed = newValue } }
    }

    fileprivate func begin() { update(+1) }
    fileprivate func end() { update(-1) }

    private func update(_ delta: Int) {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            running += delta
            return changed
        }
        callback?()
    }
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
