import Foundation

/// Cancels a task from inside work that runs on a GCD queue, where `withUnsafeCurrentTask` sees no
/// task. The work may start before the test has stored the task handle, so `cancelTask()` waits
/// until `attach(_:)` has run, then cancels it, exactly as a Stop button would.
final class LateCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private let attached = DispatchSemaphore(value: 0)
    private var cancel: (@Sendable () -> Void)?

    func attach<T: Sendable>(_ task: Task<T, Never>) {
        lock.withLock { cancel = { task.cancel() } }
        attached.signal()
    }

    /// Call only from GCD work (it may block until the task is attached).
    func cancelTask() {
        attached.wait()
        attached.signal()
        lock.withLock { cancel }?()
    }
}
