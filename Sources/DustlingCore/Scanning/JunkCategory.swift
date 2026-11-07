import Foundation

public enum JunkCategoryID: String, CaseIterable, Codable, Sendable {
    case browserCaches, xcodeJunk, packageManagerCaches, userCaches, userLogs
    case systemCachesAndLogs, trash, oldInstallers, iosBackups, xcodeArchives
    case largeOldDownloads, mailDownloads
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
}

public struct JunkItem: Sendable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let bytes: UInt64
    public let category: JunkCategoryID
    public let inUseByBundleID: String?

    public init(url: URL, bytes: UInt64, category: JunkCategoryID, inUseByBundleID: String? = nil) {
        self.url = url
        self.bytes = bytes
        self.category = category
        self.inUseByBundleID = inUseByBundleID
    }
}

public enum ScanIssue: Equatable, Sendable {
    case unreadable(URL)
    case missingFullDiskAccess(URL)
}

public struct CategoryScan: Sendable {
    public let category: JunkCategory
    public let items: [JunkItem]
    public let bytes: UInt64
    public let issues: [ScanIssue]

    public init(category: JunkCategory, items: [JunkItem], bytes: UInt64, issues: [ScanIssue]) {
        self.category = category
        self.items = items
        self.bytes = bytes
        self.issues = issues
    }
}
