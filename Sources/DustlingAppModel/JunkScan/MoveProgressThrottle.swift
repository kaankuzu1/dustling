import DustlingCore
import Foundation

/// Coalesces a cleanup's per-item callbacks, which arrive on the file-work queue, into at most one
/// main-actor update per `interval` (like the scan's progress), so a cleanup of thousands of items
/// doesn't post thousands of updates and redraws. The first item publishes at once. What is still
/// collected when the run ends is never published: the run's record replaces the progress then.
final class MoveProgressThrottle: @unchecked Sendable {
    /// What happened since the last publish.
    struct Batch: Equatable, Sendable {
        var items = 0
        var movedBytes: UInt64 = 0
        var itemsByCategory: [JunkCategoryID: Int] = [:]
    }

    private let lock = NSLock()
    private let interval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var pending = Batch()
    private var lastPublish: ContinuousClock.Instant?

    init(interval: Duration = .milliseconds(100), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.interval = interval
        self.now = now
    }

    /// Adds one finished item. Returns the batch to publish when `interval` has passed since the
    /// last publish, nil while it is still being collected.
    func add(movedBytes: UInt64, category: JunkCategoryID?) -> Batch? {
        lock.withLock {
            pending.items += 1
            pending.movedBytes += movedBytes
            if let category { pending.itemsByCategory[category, default: 0] += 1 }
            let time = now()
            if let lastPublish, lastPublish.duration(to: time) < interval { return nil }
            lastPublish = time
            defer { pending = Batch() }
            return pending
        }
    }
}
