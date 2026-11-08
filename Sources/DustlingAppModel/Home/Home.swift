import DustlingCore
import Foundation

private let gigabyte: Int64 = 1_000_000_000

/// The Home goal meter (SCREENS-final §2): 45 segments with a marker at the update size.
///
/// One segment is 1 GB (decimal, like Finder), as in the approved mockup. A goal above 30 GB scales
/// the segments up in whole gigabytes so the marker stays at or before two thirds of the meter.
public struct GoalMeter: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        /// Available now.
        case available
        /// Added by junk cleanup and Empty Trash.
        case afterCleanup
        case empty
    }

    public static let segmentCount = 45

    public let segments: [Segment]
    public let segmentBytes: Int64
    /// Where the update marker sits, 0...1 along the meter.
    public let markerFraction: Double

    public static func make(
        available: Int64, afterCleanup: Int64, needed: Int64, count: Int = segmentCount
    ) -> GoalMeter {
        let count = max(1, count)
        let available = max(0, available), after = max(0, afterCleanup), needed = max(0, needed)
        // Fill at most two thirds with the goal: 30 GB fits in 1 GB segments, 31 GB needs 2 GB ones.
        let twoThirds = Int64(count) * 2 / 3
        let unitsOfGB = max(1, (needed + twoThirds * gigabyte - 1) / (twoThirds * gigabyte))
        let unit = unitsOfGB * gigabyte
        let segments = (0..<count).map { index -> Segment in
            let middle = (Double(index) + 0.5) * Double(unit)
            if middle < Double(available) { return .available }
            if middle < Double(after) { return .afterCleanup }
            return .empty
        }
        let fraction = min(1, Double(needed) / (Double(count) * Double(unit)))
        return GoalMeter(segments: segments, segmentBytes: unit, markerFraction: fraction)
    }
}

/// The Home hero: how far the Mac is from the macOS update goal.
public enum HomeHero: Equatable, Sendable {
    case needMore(shortfall: Int64)
    case goalMet(available: Int64)

    /// `available` is `volumeAvailableCapacityForImportantUsage`, what the updater counts.
    public static func make(available: Int64, goal: UpdateGoal) -> HomeHero {
        let shortfall = goal.shortfall(available: available)
        return shortfall > 0 ? .needMore(shortfall: shortfall) : .goalMet(available: available)
    }

    public var headline: String {
        switch self {
        case .needMore(let shortfall): "You need \(Bytes.format(shortfall)) more for the macOS update"
        case .goalMet: "Ready for the macOS update"
        }
    }

    /// A caption whose first part is bold.
    public struct Caption: Equatable, Sendable {
        public let bold: String
        public let rest: String
    }

    /// "31.5 GB of safe junk is ready to go, enough on its own." The last clause only when it's true.
    /// nil when there is no safe junk to offer.
    public static func junkCaption(safeJunk: UInt64, shortfall: Int64) -> Caption? {
        guard safeJunk > 0 else { return nil }
        let enough = shortfall > 0 && safeJunk >= UInt64(shortfall)
        return Caption(
            bold: Bytes.format(safeJunk),
            rest: " of safe junk is ready to go" + (enough ? ", enough on its own." : "."))
    }

    /// "43.35 GB available. The update needs 21 GB."
    public static func goalMetCaption(available: Int64, needed: Int64) -> Caption {
        Caption(bold: Bytes.format(available), rest: " available. The update needs \(Bytes.format(needed)).")
    }
}

/// The plain-words banner about purgeable space and local snapshots (spec §7.2b, mockup H03).
public struct PurgeableNotice: Equatable, Sendable {
    /// Shown from 2 GB. The space local snapshots hold is part of the purgeable figure; macOS
    /// doesn't report it separately, so only the snapshot count is named.
    public static let threshold: Int64 = 2_000_000_000

    public let title: String
    public let message: String

    public static func make(storage: StorageInfo?) -> PurgeableNotice? {
        guard let storage else { return nil }
        let purgeable = max(0, storage.availableForImportantUsage - storage.availableBytes)
        guard purgeable >= threshold else { return nil }
        let snapshots = storage.localSnapshotCount
        let title = snapshots > 0
            ? "\(Bytes.format(purgeable)) is purgeable, including space held by \(snapshots) local Time Machine "
                + (snapshots == 1 ? "snapshot." : "snapshots.")
            : "\(Bytes.format(purgeable)) is purgeable."
        return PurgeableNotice(
            title: title,
            message: "macOS frees these by itself when it needs room, so Dustling leaves them alone. "
                + "That's also why emptying the Trash can take a moment to show up.")
    }
}

/// Hover link between the Home mosaic and what can reclaim each cell (DESIGN-mosaic §5): hovering
/// one side highlights the other and dims every other cell to 28%.
public enum HomeLink: Hashable, Sendable {
    /// Junk categories, reclaimed by Junk scan.
    case junk
    /// What is in the Trash, reclaimed by Empty Trash.
    case trash

    public static let dimmedOpacity = 0.28

    public static func link(for cell: CellKind) -> HomeLink? {
        switch cell {
        case .category: .junk
        case .inTrash: .trash
        case .free, .locked, .other: nil
        }
    }

    public static func cellOpacity(_ cell: CellKind, hovered: HomeLink?) -> Double {
        guard let hovered else { return 1 }
        return link(for: cell) == hovered ? 1 : dimmedOpacity
    }
}

/// The nibble (DESIGN-mosaic §5): while files move to the Trash, each cell shrinks to 40% and fades
/// out, 7 ms after the one before it, never later than 420 ms. Under Reduce Motion cells go at once.
public enum Nibble {
    public static let stagger = 0.007
    public static let staggerCap = 0.42
    /// How long one cell takes to shrink and fade.
    public static let duration = 0.3
    public static let finalScale = 0.4

    /// `order` is the cell's position among the cells being nibbled.
    public static func cell(order: Int, elapsed: Double, reduceMotion: Bool) -> (scale: Double, opacity: Double) {
        if reduceMotion { return (finalScale, 0) }
        let delay = min(Double(max(0, order)) * stagger, staggerCap)
        let t = min(1, max(0, (elapsed - delay) / duration))
        return (1 - (1 - finalScale) * t, 1 - t)
    }

    /// When the last of `cells` cells has gone.
    public static func totalDuration(cells: Int, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion, cells > 0 else { return 0 }
        return min(Double(cells - 1) * stagger, staggerCap) + duration
    }
}

/// A Home tool card's figure and its one line.
public struct ToolCardText: Equatable, Sendable {
    public let figure: String
    public let line: String

    public init(figure: String, line: String) {
        self.figure = figure
        self.line = line
    }
}

public enum ToolCards {
    public static let unusedAge: TimeInterval = 90 * 24 * 60 * 60

    public static func junk(safeBytes: UInt64, reviewBytes: UInt64, shortfall: Int64) -> ToolCardText {
        let line: String
        if shortfall > 0 && safeBytes >= UInt64(shortfall) {
            line = "Enough for the update on its own"
        } else if reviewBytes > 0 {
            line = "safe to remove, plus \(Bytes.format(reviewBytes)) to review"
        } else {
            line = "safe to remove"
        }
        return ToolCardText(figure: Bytes.format(safeBytes), line: line)
    }

    /// The figure is what removing the apps that have leftovers would free.
    public static func uninstaller(_ apps: [AppRow], now: Date) -> ToolCardText {
        let withLeftovers = apps.filter { $0.leftoverCount > 0 }
        let bytes = withLeftovers.reduce(UInt64(0)) { $0 + $1.totalBytes }
        let unused = apps.filter { row in
            guard let used = row.app.lastUsed else { return false }
            return now.timeIntervalSince(used) > unusedAge
        }.count
        var line = withLeftovers.count == 1 ? "1 app with leftovers" : "\(withLeftovers.count) apps with leftovers"
        if unused > 0 { line += ", \(unused) not opened in 90 days" }
        return ToolCardText(figure: Bytes.format(bytes), line: line)
    }

    public static func startup(_ items: [StartupItem], orphanCount: Int) -> ToolCardText {
        let on = items.filter(\.isEnabled).count
        let line: String
        switch orphanCount {
        case ...0: line = "Nothing to review"
        case 1: line = "1 belongs to an app you removed"
        default: line = "\(orphanCount) belong to apps you removed"
        }
        return ToolCardText(figure: "\(on) on", line: line)
    }
}

/// "just now", "2 minutes ago": how long ago a scan or cleanup finished, in plain English.
public enum ScanAge {
    public static func text(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return unit(seconds / 60, "minute")
        case ..<86_400: return unit(seconds / 3_600, "hour")
        default: return unit(seconds / 86_400, "day")
        }
    }
}

/// The Home mosaic: everything Dustling could reclaim, one cell per quarter gigabyte. Unlike the
/// storage mosaic it has no free or "other" cells.
public enum HomeMosaic {
    /// `excluding`: categories a finished cleanup moved to the Trash (they now count in `trashBytes`).
    /// `trashBytes` nil means the Trash couldn't be read. Places that are locked or unreadable get
    /// one hatched cell each, and so does an unreadable Trash in a place that reads as open.
    public static func layout(
        tiles: [CategoryTileModel], excluding: Set<JunkCategoryID>, trashBytes: UInt64?, places: [Place]?
    ) -> MosaicLayout {
        let shown = tiles.filter { !excluding.contains($0.id) && $0.id != .trash }
        return MosaicLayout.make(
            totalBytes: 0, availableBytes: 0, categories: shown.map { ($0.id, $0.bytes) },
            inTrashBytes: trashBytes ?? 0, lockedPlaces: lockedCount(places: places, trashReadable: trashBytes != nil))
    }

    public static func lockedCount(places: [Place]?, trashReadable: Bool) -> Int {
        let places = places ?? []
        var count = places.filter { $0.access != .readable }.count
        let trashPlaceOpen = places.first { $0.id == .trash }.map { $0.access == .readable } ?? true
        if !trashReadable && trashPlaceOpen { count += 1 }
        return count
    }

    public static func reclaimableBytes(
        tiles: [CategoryTileModel], excluding: Set<JunkCategoryID>, trashBytes: UInt64?
    ) -> UInt64 {
        tiles.filter { !excluding.contains($0.id) && $0.id != .trash }.reduce(trashBytes ?? 0) { $0 + $1.bytes }
    }

    /// The categories a scan may open: only places that read as open. Nil places (not checked yet)
    /// scan nothing, so a scan never opens a folder that would ask for consent.
    public static func scannable(_ catalog: [JunkCategory], places: [Place]?) -> [JunkCategory] {
        guard let places else { return [] }
        let access = Dictionary(places.map { ($0.id, $0.access) }, uniquingKeysWith: { first, _ in first })
        return catalog.filter { access[$0.id] == .readable }
    }

    /// What VoiceOver reads for the mosaic.
    public static func accessibilitySummary(reclaimable: UInt64, categories: Int, locked: Int) -> String {
        var text = "Reclaimable: \(Bytes.format(reclaimable)) in \(categories) \(categories == 1 ? "category" : "categories")"
        if locked > 0 { text += "; \(locked) \(locked == 1 ? "place" : "places") locked" }
        return text
    }
}
