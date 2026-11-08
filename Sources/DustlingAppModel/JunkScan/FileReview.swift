import DustlingCore
import Foundation

/// The Review files sheet: every file a cleanup of the selected categories would look at, grouped by
/// category in tile order, with the ones that can't move disabled and their reason.
public struct FileReview: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: URL { url }
        public let url: URL
        public let name: String
        public let bytes: UInt64
        /// Why this file can't move (in use, needs the helper, locked, outside the cleanup area); nil
        /// when it can.
        public let disabledReason: String?
        /// True when it would move: not disabled and not left out.
        public let isIncluded: Bool
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let id: JunkCategoryID
        public let title: String
        /// Largest first; files that can't move come last.
        public let rows: [Row]
        public let selectedBytes: UInt64
        public let selectedCount: Int
    }

    public let sections: [Section]

    public var selectedBytes: UInt64 { sections.reduce(0) { $0 + $1.selectedBytes } }
    public var selectedCount: Int { sections.reduce(0) { $0 + $1.selectedCount } }

    /// The footer's "N files selected, X".
    public var footerLine: String {
        "\(selectedCount == 1 ? "1 file" : "\(selectedCount) files") selected, \(Bytes.format(selectedBytes))"
    }

    /// The same list with `excluding` left out: rows and order stay, only what's ticked and the totals
    /// change. The sheet calls this on every tick, so a long list isn't sorted again.
    public func applying(excluding: Set<URL>) -> FileReview {
        FileReview(sections: sections.map { section in
            let rows = section.rows.map { row in
                Row(url: row.url, name: row.name, bytes: row.bytes, disabledReason: row.disabledReason,
                    isIncluded: row.disabledReason == nil && !excluding.contains(row.url))
            }
            let included = rows.filter(\.isIncluded)
            return Section(
                id: section.id, title: section.title, rows: rows,
                selectedBytes: included.reduce(0) { $0 + $1.bytes }, selectedCount: included.count)
        })
    }

    /// Why an item can't move, in the order a cleanup would decide it.
    static func disabledReason(
        _ item: JunkItem, category: JunkCategory, skipping: CleanupSkip, appName: (String) -> String?
    ) -> String? {
        if skipping.skips(item) { return "Needs Full Disk Access" }
        if let owner = item.inUseByBundleID { return "In use by \(appName(owner) ?? owner)" }
        if category.requiresAdmin { return "Needs the cleanup helper" }
        if !category.isDeclaredRoot(item.url.deletingLastPathComponent()) { return "Outside the cleanup area" }
        return nil
    }
}
