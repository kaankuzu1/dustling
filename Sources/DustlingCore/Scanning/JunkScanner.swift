import Foundation

public struct JunkScanner: Sendable {
    private let environment: SystemEnvironment
    private let runningBundleIDs: @Sendable () -> Set<String>

    public init(environment: SystemEnvironment, runningBundleIDs: @escaping @Sendable () -> Set<String>) {
        self.environment = environment
        self.runningBundleIDs = runningBundleIDs
    }

    /// Scans categories in order. An item already claimed by an earlier category is skipped. Throws
    /// `CancellationError` if the task is cancelled. `onCategory` fires as each category finishes.
    public func scan(
        _ categories: [JunkCategory],
        onCategory: @Sendable (CategoryScan) -> Void
    ) async throws -> [CategoryScan] {
        let running = runningBundleIDs()
        let sizer = DirectorySizer()
        var claimed = Set<String>()
        var results: [CategoryScan] = []

        for category in categories {
            try Task.checkCancellation()
            var items: [JunkItem] = []
            var issues: [ScanIssue] = []

            for root in category.roots {
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                let children: [URL]
                do {
                    children = try FileManager.default.contentsOfDirectory(
                        at: root, includingPropertiesForKeys: nil)
                } catch {
                    issues.append(.missingFullDiskAccess(root))
                    continue
                }
                for child in children.sorted(by: { $0.path < $1.path }) {
                    try Task.checkCancellation()
                    guard category.itemFilter(child), !claimed.contains(child.path) else { continue }
                    claimed.insert(child.path)
                    let size = sizer.measure(child)
                    issues.append(contentsOf: size.unreadable.map { .unreadable($0) })
                    let name = child.lastPathComponent
                    items.append(JunkItem(
                        url: child, bytes: size.bytes, category: category.id,
                        inUseByBundleID: running.contains(name) ? name : nil))
                }
            }

            let scan = CategoryScan(
                category: category, items: items,
                bytes: items.reduce(0) { $0 + $1.bytes }, issues: issues)
            results.append(scan)
            onCategory(scan)
        }
        return results
    }
}
