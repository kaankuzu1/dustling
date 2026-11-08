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
    public var footerLine: String { Self.footerLine(count: selectedCount, bytes: selectedBytes) }

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

    /// Why an item can't move, in words for the sheet (`Unmovable.check` decides).
    static func disabledReason(
        _ item: JunkItem, category: JunkCategory, skipping: CleanupSkip, inUseBy: String?, appName: (String) -> String?
    ) -> String? {
        Unmovable.check(item, category: category, skipping: skipping, inUseBy: inUseBy)?.text(appName: appName)
    }

    /// Only the selection totals for `excluding`, without rebuilding any rows (for live totals).
    public func totals(excluding: Set<URL>) -> (sections: [JunkCategoryID: UInt64], count: Int, bytes: UInt64) {
        var perSection: [JunkCategoryID: UInt64] = [:], count = 0, bytes: UInt64 = 0
        for section in sections {
            var sum: UInt64 = 0
            for row in section.rows where row.disabledReason == nil && !excluding.contains(row.url) {
                sum += row.bytes
                count += 1
            }
            perSection[section.id] = sum
            bytes += sum
        }
        return (perSection, count, bytes)
    }

    /// "N files selected, X" for any count and size.
    public static func footerLine(count: Int, bytes: UInt64) -> String {
        "\(count == 1 ? "1 file" : "\(count) files") selected, \(Bytes.format(bytes))"
    }
}

/// The one rule for whether a scanned item can move to the Trash now. The Review files list, the
/// selected totals (action bar, confirm alert, Home) and `clean()` all ask it, so they always agree.
public enum Unmovable: Equatable, Sendable {
    /// Its place can't be read now (access revoked since the scan, or a locked container folder).
    case locked
    /// An app that is open right now owns it.
    case inUse(bundleID: String)
    /// Only the cleanup helper could move it.
    case needsHelper
    /// It isn't directly inside one of the category's folders.
    case outsideCleanupArea

    /// nil when the item can move. `inUseBy`: the running app that owns it right now, if any (the
    /// junk model decides this from a live running set; nil leaves in-use out of the check).
    public static func check(
        _ item: JunkItem, category: JunkCategory, skipping: CleanupSkip, inUseBy: String?
    ) -> Unmovable? {
        if skipping.skips(item) { return .locked }
        if let owner = inUseBy { return .inUse(bundleID: owner) }
        if category.requiresAdmin { return .needsHelper }
        if !category.isDeclaredRoot(item.url.deletingLastPathComponent()) { return .outsideCleanupArea }
        return nil
    }

    /// The reason in the sheet.
    public func text(appName: (String) -> String?) -> String {
        switch self {
        case .locked: "Needs Full Disk Access"
        case .inUse(let id): "In use by \(appName(id) ?? id)"
        case .needsHelper: "Needs the cleanup helper"
        case .outsideCleanupArea: "Outside the cleanup area"
        }
    }

    /// What the run records for it.
    public var outcome: DeletionOutcome {
        switch self {
        case .locked: .skipped(reason: CleanupSkip.reason)
        case .inUse(let id): .skipped(reason: "in use by \(id)")
        case .needsHelper: .needsAdmin
        case .outsideCleanupArea: .skipped(reason: "outside the cleanup area")
        }
    }
}
