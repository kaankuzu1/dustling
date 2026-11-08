import Foundation

/// Runs blocking file work (scanning, measuring, moving to the Trash, journaling) on a dedicated GCD
/// queue and awaits the result, so it never holds a thread of Swift's cooperative pool. A few long
/// scans there could use up every pool thread and stall unrelated tasks, tests included.
///
/// `Task.isCancelled` doesn't carry over to GCD, so cancelling the awaiting task sets a flag that the
/// work reads through the `isCancelled` closure it is handed.
enum FileWork {
    static let queue = DispatchQueue(
        label: "app.dustling.file-work", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(
        _ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) -> T
    ) async -> T {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: work { flag.isSet }) }
            }
        } onCancel: {
            flag.set()
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// A one-way flag set from a cancellation handler and read from GCD work.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
