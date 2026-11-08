import DustlingCore
import Foundation

/// Why a leftover won't move now (`UninstallerModel.block(for:)`, the one rule).
public enum LeftoverBlock: Equatable, Sendable {
    /// Excluded in Settings, or only the link of a shortcut is removed.
    case excluded(String)
    /// Only the cleanup helper could move it.
    case needsHelper
    /// Its folder can't be read without Full Disk Access.
    case needsFullDiskAccess

    public var text: String {
        switch self {
        case .excluded(let reason): UninstallerScreen.sentence(reason)
        case .needsHelper: UninstallerScreen.helperNote
        case .needsFullDiskAccess: "Needs Full Disk Access"
        }
    }
}

/// Review all files: one section per selected app, the app first, then its leftovers.
public struct UninstallReview: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public let url: URL
        /// "Application", "Shortcut" or the leftover's kind.
        public let title: String
        /// The app bundle itself: unticking it deselects the app.
        public let isApp: Bool
        public let bytes: UInt64
        public let badges: [LeftoverBadge]
        /// Why it can't move; nil when it can be ticked.
        public let disabledReason: String?
        /// Ticked when the sheet opened.
        public let isIncluded: Bool
        /// "This is your data. …", shown while a data row is ticked.
        public let dataWarning: String?
        public var id: URL { url }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let app: InstalledApp
        public let rows: [Row]
        public var id: URL { app.url }
    }

    public let sections: [Section]

    public var selectedBytes: UInt64 { sections.reduce(0) { $0 + $1.rows.filter(\.isIncluded).reduce(0) { $0 + $1.bytes } } }
    public var selectedCount: Int { sections.reduce(0) { $0 + $1.rows.filter(\.isIncluded).count } }

    /// Live totals for a draft: an unticked app counts nothing; otherwise the rows that can move and
    /// aren't left out.
    public func totals(excluding: Set<URL>) -> (sections: [URL: UInt64], count: Int, bytes: UInt64) {
        var perSection: [URL: UInt64] = [:], count = 0, bytes: UInt64 = 0
        for section in sections {
            var sum: UInt64 = 0
            if !excluding.contains(section.id) {
                for row in section.rows where row.disabledReason == nil && !excluding.contains(row.url) {
                    sum += row.bytes
                    count += 1
                }
            }
            perSection[section.id] = sum
            bytes += sum
        }
        return (perSection, count, bytes)
    }

    /// "N files selected, X".
    public static func footerLine(count: Int, bytes: UInt64) -> String {
        "\(count == 1 ? "1 file" : "\(count) files") selected, \(Bytes.format(bytes))"
    }
}
