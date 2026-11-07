import Foundation

public struct JunkScanner: Sendable {
    private let environment: SystemEnvironment
    private let runningBundleIDs: @Sendable () -> Set<String>

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
            let resolved = resolveRoots(category)
            var issues = resolved.issues

            for root in resolved.roots {
                let children: [URL]
                switch Self.list(root) {
                case .success(let c): children = c
                case .failure(.missing): continue
                case .failure(.denied): issues.append(.missingFullDiskAccess(root)); continue
                case .failure: issues.append(.unreadable(root)); continue
                }
                for child in children.sorted(by: { $0.path < $1.path }) {
                    try Task.checkCancellation()
                    guard category.itemFilter(child), !claimed.contains(child.path) else { continue }
                    let size = sizer.measure(child)
                    if let measured = category.measuredFilter {
                        do {
                            guard try measured(child, size) else { continue }
                        } catch {
                            issues.append(.unreadable(child))
                            continue
                        }
                    }
                    claimed.insert(child.path)
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
