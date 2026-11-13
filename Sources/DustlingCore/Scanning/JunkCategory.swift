import Foundation

public enum JunkCategoryID: String, CaseIterable, Codable, Sendable {
    case browserCaches, xcodeJunk, packageManagerCaches, userCaches, userLogs
    case systemCachesAndLogs, trash, oldInstallers, iosBackups, xcodeArchives
    case largeOldDownloads, mailDownloads

    /// System caches and logs: macOS manages what is in them, so Dustling shows their size and never
    /// cleans them (`JunkCategory.isNeverCleaned`). Nothing it holds counts as space Dustling can free.
    public var isNeverCleaned: Bool { self == .systemCachesAndLogs }
}

public enum Selection: Sendable {
    /// Safe to regenerate: ticked by default.
    case preselected
    /// The user must choose.
    case review
    /// Only ever emptied as a whole, never ticked per item.
    case emptyTrashOnly
}

/// Roots found by listing `parent` and appending `subpath` to each child (a glob such as
/// `Containers/*/Data/Library/Caches`). Resolved by the scanner so listing failures surface as issues.
public struct RootExpansion: Sendable {
    public let parent: URL
    public let subpath: String
    public init(parent: URL, subpath: String) {
        self.parent = parent
        self.subpath = subpath
    }
}

/// One cleanable category. The unit of deletion is each direct child of a root that passes `itemFilter`.
public struct JunkCategory: Sendable {
    public let id: JunkCategoryID
    public let title: String
    public let selection: Selection
    public let requiresAdmin: Bool
    public let roots: [URL]
    public let expansions: [RootExpansion]
    public let itemFilter: @Sendable (URL) -> Bool
    /// Decides inclusion once the item has been measured (so it is measured only once). Throwing means
    /// the item's attributes could not be read: it is reported as `.unreadable` and left out.
    public let measuredFilter: (@Sendable (URL, SizeResult) throws -> Bool)?

    public init(
        id: JunkCategoryID, title: String, selection: Selection, requiresAdmin: Bool,
        roots: [URL], expansions: [RootExpansion] = [],
        itemFilter: @escaping @Sendable (URL) -> Bool = { _ in true },
        measuredFilter: (@Sendable (URL, SizeResult) throws -> Bool)? = nil
    ) {
        self.id = id
        self.title = title
        self.selection = selection
        self.requiresAdmin = requiresAdmin
        self.roots = roots
        self.expansions = expansions
        self.itemFilter = itemFilter
        self.measuredFilter = measuredFilter
    }

    /// Cleaned without being asked for: preselected, not needing admin rights and not one Dustling
    /// leaves alone.
    public var isSelectedByDefault: Bool { selection == .preselected && !requiresAdmin && !isNeverCleaned }

    /// Shown with its size, never cleaned: macOS manages what is in it (System caches and logs). Not
    /// ticked, not even by choice, never retried, never moved with the Mac password, and refused by
    /// `dustling-cli clean --include`. The guard every move goes through (`ProtectedPaths`) refuses
    /// what is in its folders too.
    public var isNeverCleaned: Bool { id.isNeverCleaned }

    /// True when `folder` is one of this category's fixed roots, or one root an expansion produces
    /// (`<expansion.parent>/<one child>/<expansion.subpath>`). Cleaning uses only these folders as the
    /// allowed roots, so an item that isn't a direct child of one is never touched.
    public func isDeclaredRoot(_ folder: URL) -> Bool {
        let path = Self.components(folder)
        if roots.contains(where: { Self.components($0) == path }) { return true }
        return expansions.contains { expansion in
            let parent = Self.components(expansion.parent)
            let sub = expansion.subpath.split(separator: "/").map(String.init)
            return path.count == parent.count + 1 + sub.count
                && Array(path.prefix(parent.count)) == parent
                && Array(path.suffix(sub.count)) == sub
        }
    }

    /// Standardized (`.`/`..` removed) path components, without the leading "/".
    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.path(percentEncoded: false).split(separator: "/").map(String.init)
    }
}

public struct JunkItem: Sendable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let bytes: UInt64
    public let category: JunkCategoryID
    public let inUseByBundleID: String?
    /// The app the item belongs to, running or not (from its folder name), so callers can tell later
    /// whether it is in use. Falls back to `inUseByBundleID`.
    public let ownerBundleID: String?

    public init(
        url: URL, bytes: UInt64, category: JunkCategoryID, inUseByBundleID: String? = nil, ownerBundleID: String? = nil
    ) {
        self.url = url
        self.bytes = bytes
        self.category = category
        self.inUseByBundleID = inUseByBundleID
        self.ownerBundleID = ownerBundleID ?? inUseByBundleID
    }
}

public enum ScanIssue: Equatable, Sendable {
    case unreadable(URL)
    case missingFullDiskAccess(URL)
    case commandFailed(command: String, reason: String)
}

/// A live snapshot of a running scan, for a "space found" counter and a path ticker.
/// Live only; final totals must come from the returned CategoryScans.
public struct ScanProgress: Sendable {
    public let currentPath: URL
    /// Bytes found so far. Never decreases during one scan.
    public let bytesFound: UInt64
    public let categoriesDone: Int
    public let categoriesTotal: Int

    public init(currentPath: URL, bytesFound: UInt64, categoriesDone: Int, categoriesTotal: Int) {
        self.currentPath = currentPath
        self.bytesFound = bytesFound
        self.categoriesDone = categoriesDone
        self.categoriesTotal = categoriesTotal
    }
}

public struct CategoryScan: Sendable {
    public let category: JunkCategory
    public let items: [JunkItem]
    public let bytes: UInt64
    public let issues: [ScanIssue]
    /// True when the scan was stopped while this category was in progress: `items` and `bytes` are only
    /// what had been fully measured, never the category's real total.
    public let stopped: Bool

    public init(
        category: JunkCategory, items: [JunkItem], bytes: UInt64, issues: [ScanIssue], stopped: Bool = false
    ) {
        self.stopped = stopped
        self.category = category
        self.items = items
        self.bytes = bytes
        self.issues = issues
    }
}
