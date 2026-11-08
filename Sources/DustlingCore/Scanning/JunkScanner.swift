import Foundation

public struct JunkScanner: Sendable {
    private let environment: SystemEnvironment
    private let runningBundleIDs: @Sendable () -> Set<String>
    /// Minimum gap between progress events. Tests shorten it; the app always uses 100 ms.
    var progressInterval: Duration = .milliseconds(100)

    public init(environment: SystemEnvironment, runningBundleIDs: @escaping @Sendable () -> Set<String>) {
        self.environment = environment
        self.runningBundleIDs = runningBundleIDs
    }

    private enum Access: Error { case ok, missing, denied, other }

    private static func classify(errno code: Int32) -> Access {
        switch code {
        case ENOENT, ENOTDIR: .missing
        case EPERM, EACCES: .denied
        default: .other
        }
    }

    private static func probe(_ url: URL) -> Access {
        var st = stat()
        return stat(url.path, &st) == 0 ? .ok : classify(errno: errno)
    }

    /// Lists `url`. Failures are classified from the POSIX error behind the Cocoa error.
    private static func list(_ url: URL) -> Result<[URL], Access> {
        do {
            return .success(try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
        } catch let error as NSError {
            var posix: Int32?
            if error.domain == NSPOSIXErrorDomain { posix = Int32(error.code) }
            if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
                posix = Int32(under.code)
            }
            if let posix { return .failure(posix == ENOTDIR ? .other : classify(errno: posix)) }
            switch error.code {
            case NSFileReadNoPermissionError: return .failure(.denied)
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .failure(.missing)
            default: return .failure(.other)
            }
        }
    }

    /// Resolves a category's roots. ENOENT is skipped silently; permission failures become
    /// `.missingFullDiskAccess`; any other failure becomes `.unreadable`.
    private func resolveRoots(_ category: JunkCategory) -> (roots: [URL], issues: [ScanIssue]) {
        var roots: [URL] = []
        var issues: [ScanIssue] = []

        func check(_ url: URL) {
            switch Self.probe(url) {
            case .ok: roots.append(url)
            case .missing: break
            case .denied: issues.append(.missingFullDiskAccess(url))
            case .other: issues.append(.unreadable(url))
            }
        }

        category.roots.forEach(check)
        for expansion in category.expansions {
            switch Self.probe(expansion.parent) {
            case .missing: continue
            case .denied: issues.append(.missingFullDiskAccess(expansion.parent)); continue
            case .other: issues.append(.unreadable(expansion.parent)); continue
            case .ok: break
            }
            switch Self.list(expansion.parent) {
            case .success(let children):
                children.sorted { $0.path < $1.path }
                    .forEach { check($0.appending(path: expansion.subpath)) }
            case .failure(.missing): break
            case .failure(.denied): issues.append(.missingFullDiskAccess(expansion.parent))
            case .failure: issues.append(.unreadable(expansion.parent))
            }
        }
        return (roots, issues)
    }

    /// Throttles and clamps progress: at most one event per 100 ms (monotonic clock), `bytesFound` never
    /// decreases, and `finish` always emits. Used from one task only.
    private final class ProgressEmitter {
        private let total: Int
        private let interval: Duration
        private let sink: @Sendable (ScanProgress) -> Void
        private var last: ContinuousClock.Instant?
        private var highWater: UInt64 = 0
        var done = 0
        init(total: Int, interval: Duration, sink: @escaping @Sendable (ScanProgress) -> Void) {
            self.total = total
            self.interval = interval
            self.sink = sink
        }
        func tick(_ path: URL, bytes: UInt64) {
            let now = ContinuousClock.now
            if let last, last.duration(to: now) < interval { return }
            emit(path, bytes, at: now)
        }
        func finish(_ path: URL, bytes: UInt64) { emit(path, bytes, at: .now) }
        private func emit(_ path: URL, _ bytes: UInt64, at now: ContinuousClock.Instant) {
            last = now
            highWater = max(highWater, bytes)
            sink(ScanProgress(currentPath: path, bytesFound: highWater, categoriesDone: done, categoriesTotal: total))
        }
    }

    /// Scans categories in order. An item already claimed by an earlier category is skipped. `onCategory`
    /// fires as each category finishes. `onProgress` is throttled to one call per 100 ms, plus one when
    /// each category completes.
    ///
    /// Cancelling the task stops the scan even in the middle of a big folder and never throws: the result
    /// holds the finished categories plus, if one was in progress, that category with `stopped = true`
    /// and only the items fully measured (an item cut off mid-measurement is dropped, not shown with a
    /// partial size). If the cancel lands between categories, the next category is returned as stopped with no items.
    ///
    /// The file work runs on a GCD queue (`FileWork`), so the callbacks arrive on that queue.
    public func scan(
        _ categories: [JunkCategory],
        onCategory: @escaping @Sendable (CategoryScan) -> Void,
        onProgress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async -> [CategoryScan] {
        await FileWork.run { isCancelled in
            scanBlocking(categories, isCancelled: isCancelled, onCategory: onCategory, onProgress: onProgress)
        }
    }

    /// The scan itself, synchronous. `isCancelled` replaces `Task.isCancelled`, which GCD work can't see.
    func scanBlocking(
        _ categories: [JunkCategory],
        isCancelled: @escaping @Sendable () -> Bool,
        onCategory: @Sendable (CategoryScan) -> Void,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) -> [CategoryScan] {
        let running = runningBundleIDs()
        let sizer = DirectorySizer()
        var claimed = Set<String>()
        var results: [CategoryScan] = []
        let progress = ProgressEmitter(total: categories.count, interval: progressInterval, sink: onProgress)
        var committed: UInt64 = 0   // bytes of items accepted so far, across categories

        for category in categories {
            if isCancelled() {
                // Cancelled between categories: say so, never let a truncated scan look complete.
                let notStarted = CategoryScan(category: category, items: [], bytes: 0, issues: [], stopped: true)
                results.append(notStarted)
                onCategory(notStarted)
                break
            }
            var items: [JunkItem] = []
            let resolved = resolveRoots(category)
            var issues = resolved.issues
            var stopped = false
            var lastPath = category.roots.first ?? URL(filePath: "/")

            rootLoop: for root in resolved.roots {
                if isCancelled() { stopped = true; break }
                let children: [URL]
                switch Self.list(root) {
                case .success(let c): children = c
                case .failure(.missing): continue
                case .failure(.denied): issues.append(.missingFullDiskAccess(root)); continue
                case .failure: issues.append(.unreadable(root)); continue
                }
                for child in children.sorted(by: { $0.path < $1.path }) {
                    if isCancelled() { stopped = true; break rootLoop }
                    guard category.itemFilter(child), !claimed.contains(child.path) else { continue }
                    lastPath = child
                    progress.tick(child, bytes: committed)
                    let base = committed
                    // With a measuredFilter the item may still be rejected, so its in-flight bytes are not
                    // counted until it is accepted; otherwise the counter would overshoot for good.
                    let countsInFlight = category.measuredFilter == nil
                    let size = sizer.measure(
                        child, isCancelled: isCancelled,
                        onEntry: { path, soFar in progress.tick(path, bytes: base + (countsInFlight ? soFar : 0)) })
                    if size.cancelled { stopped = true; break rootLoop }
                    if let measured = category.measuredFilter {
                        do {
                            guard try measured(child, size) else { continue }
                        } catch {
                            issues.append(.unreadable(child))
                            continue
                        }
                    }
                    claimed.insert(child.path)
                    committed += size.bytes
                    issues.append(contentsOf: size.unreadable.map { .unreadable($0) })
                    let owner = JunkCatalog.ownerBundleID(of: child)
                    items.append(JunkItem(
                        url: child, bytes: size.bytes, category: category.id,
                        inUseByBundleID: running.contains(owner) ? owner : nil, ownerBundleID: owner))
                }
            }

            let scan = CategoryScan(
                category: category, items: items,
                bytes: items.reduce(0) { $0 + $1.bytes }, issues: issues, stopped: stopped)
            results.append(scan)
            onCategory(scan)
            if !stopped { progress.done += 1 }
            progress.finish(lastPath, bytes: committed)
            if stopped { break }
        }
        return results
    }
}
