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
            message: "macOS frees this space by itself when it needs room, so Dustling leaves it alone. "
                + "That's also why space from emptying the Trash can take a moment to show up.")
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

    /// `allClean`: the last scan found nothing to move (`JunkScreen.isAllClean`).
    public static func junk(safeBytes: UInt64, reviewBytes: UInt64, shortfall: Int64, allClean: Bool = false) -> ToolCardText {
        let line: String
        if allClean {
            line = "All clean"
        } else if shortfall > 0 && safeBytes >= UInt64(shortfall) {
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

/// The counts next to the sidebar's destinations (the approved shell's `.w-badge`): what a clean
/// would move, how many apps the Uninstaller lists, and startup items that need a look. nil hides a badge,
/// so a quiet screen has none.
public enum SidebarBadges {
    public struct Badge: Equatable, Sendable {
        public let text: String
        /// Drawn in `warning`, semibold: something to review.
        public let needsAttention: Bool

        public init(text: String, needsAttention: Bool = false) {
            self.text = text
            self.needsAttention = needsAttention
        }
    }

    /// The selected junk, once a scan has finished. Nothing while scanning or after a cleanup.
    public static func junk(_ figures: HomeFigures) -> Badge? {
        guard figures.scanFinished, figures.phase != .done, figures.safeJunk > 0 else { return nil }
        return Badge(text: Bytes.short(figures.safeJunk))
    }

    /// The apps the Uninstaller lists, the same count as its subtitle, once it has looked.
    public static func uninstaller(_ apps: [AppRow]?) -> Badge? {
        guard let apps else { return nil }
        let count = apps.count
        guard count > 0 else { return nil }
        return Badge(text: count == 1 ? "1 app" : "\(count) apps")
    }

    /// Startup items that belong to apps that are gone.
    public static func startup(orphanCount: Int?) -> Badge? {
        guard let orphanCount, orphanCount > 0 else { return nil }
        return Badge(text: "\(orphanCount) to review", needsAttention: true)
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
    /// `lockedCells`: one hatched cell per place Dustling couldn't read or scan (`HomeFigures`).
    public static func layout(
        tiles: [CategoryTileModel], excluding: Set<JunkCategoryID>, trashBytes: UInt64?, lockedCells: Int
    ) -> MosaicLayout {
        let shown = tiles.filter { !excluding.contains($0.id) && $0.id != .trash }
        return MosaicLayout.make(
            totalBytes: 0, availableBytes: 0, categories: shown.map { ($0.id, $0.bytes) },
            inTrashBytes: trashBytes ?? 0, lockedPlaces: lockedCells)
    }

    public static func reclaimableBytes(
        tiles: [CategoryTileModel], excluding: Set<JunkCategoryID>, trashBytes: UInt64?
    ) -> UInt64 {
        tiles.filter { !excluding.contains($0.id) && $0.id != .trash }.reduce(trashBytes ?? 0) { $0 + $1.bytes }
    }

    /// The categories a scan may open: only places that read as open, without their locked
    /// expansions. Nil places (not checked yet) scan nothing, so a scan never opens a folder that
    /// would ask for consent. The Trash is left out: `TrashModel` reads it, and only with Full Disk
    /// Access does it look at other volumes.
    public static func scannable(_ catalog: [JunkCategory], places: [Place]?) -> [JunkCategory] {
        guard let places else { return [] }
        let byID = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return catalog.compactMap { category in
            category.id == .trash ? nil : PlaceAccessChecker.scannableCategory(category, place: byID[category.id])
        }
    }

    /// What VoiceOver reads for the mosaic.
    public static func accessibilitySummary(reclaimable: UInt64, categories: Int, locked: Int) -> String {
        var text = "Reclaimable: \(Bytes.format(reclaimable)) in \(categories) \(categories == 1 ? "category" : "categories")"
        if locked > 0 { text += "; \(locked) \(locked == 1 ? "place" : "places") locked" }
        return text
    }
}

/// Which places a junk scan covered: fully, or only their plain roots (expansions locked).
public struct HomeScanScope: Equatable, Sendable {
    public var full: Set<JunkCategoryID>
    public var partial: Set<JunkCategoryID>

    public init(full: Set<JunkCategoryID> = [], partial: Set<JunkCategoryID> = []) {
        self.full = full
        self.partial = partial
    }

    /// The scope a scan of `HomeMosaic.scannable(_, places:)` has.
    public static func make(places: [Place]?) -> HomeScanScope {
        var scope = HomeScanScope()
        for place in places ?? [] where place.access == .readable && place.id != .trash {
            if place.lockedExpansions { scope.partial.insert(place.id) } else { scope.full.insert(place.id) }
        }
        return scope
    }

    /// True when `places` now open something this scope didn't scan: a new place, or the locked part
    /// of a partly scanned one. Home then scans again.
    public func isOutgrown(by places: [Place]?) -> Bool {
        let now = Self.make(places: places)
        return !now.full.isSubset(of: full) || !now.partial.isSubset(of: full.union(partial))
    }

    /// Home scans again when places opened that this scope didn't cover, but only while the junk
    /// model is at rest: never during a scan or a cleanup, and never over a cleanup's summary.
    public func shouldRescan(places: [Place]?, phase: HomeFigures.Phase) -> Bool {
        switch phase {
        case .notScanned, .ready: isOutgrown(by: places)
        case .scanning, .moving, .done: false
        }
    }
}

/// What Home shows, worked out from the shared models' state in one place.
public struct HomeFigures: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case notScanned, scanning, ready, moving, done }

    /// The Trash as `TrashModel` last read it.
    public enum TrashReading: Equatable, Sendable {
        case unknown
        /// `externalSkipped`: other volumes' Trash folders weren't opened (no Full Disk Access): a
        /// lower bound, shown with a locked cell. `systemUnread`: some items that belong to the system
        /// couldn't be read (they are deleted with the Mac password): a lower bound, nothing locked.
        case read(bytes: UInt64, externalSkipped: Bool, systemUnread: Bool = false)
        /// The Trash couldn't be read; `movedSinceLastEmpty` is what Dustling's own runs put there.
        case unreadable(movedSinceLastEmpty: UInt64)
    }

    public struct Input: Sendable {
        public var available: Int64?
        public var goal: UpdateGoal
        public var phase: Phase
        public var tiles: [CategoryTileModel]
        /// `JunkScanModel.selectedBytesByCategory`: what a clean would move, per category.
        public var selectedBytes: [JunkCategoryID: UInt64]
        public var trash: TrashReading
        public var places: [Place]?
        /// The scope of the last junk scan; nil before one.
        public var scanScope: HomeScanScope?

        public init(
            available: Int64?, goal: UpdateGoal, phase: Phase, tiles: [CategoryTileModel], selectedBytes: [JunkCategoryID: UInt64],
            trash: TrashReading, places: [Place]?, scanScope: HomeScanScope?
        ) {
            self.available = available
            self.goal = goal
            self.phase = phase
            self.tiles = tiles
            self.selectedBytes = selectedBytes
            self.trash = trash
            self.places = places
            self.scanScope = scanScope
        }
    }

    /// `volumeAvailableCapacityForImportantUsage`, what the macOS updater counts. nil until read.
    public let available: Int64?
    public let hero: HomeHero?
    /// True once a scan has finished and no scan is running.
    public let scanFinished: Bool
    public let safeJunk: UInt64
    public let reviewJunk: UInt64
    /// What the Trash cells and the meter count: everything in the Trash, or (unreadable) at least what
    /// Dustling moved there. nil while unread.
    public let trashBytes: UInt64?
    public let trashIsLowerBound: Bool
    public let reclaimable: UInt64?
    /// Something wasn't read or scanned in full: totals read "or more".
    public let isLowerBound: Bool
    /// Available after junk cleanup and Empty Trash; nil until storage is read.
    public let afterCleanup: Int64?
    public let afterCleanupIsLowerBound: Bool
    public let lockedCells: Int
    public let mosaic: MosaicLayout
    public let mosaicSummary: String
    /// Categories a finished cleanup moved to the Trash.
    public let cleaned: Set<JunkCategoryID>
    /// Categories being moved right now; their cells nibble away.
    public let nibbling: Set<JunkCategoryID>
    public let phase: Phase

    public var shortfall: Int64 {
        if case .needMore(let shortfall) = hero { return shortfall }
        return 0
    }

    public static func make(_ input: Input) -> HomeFigures {
        var input = input
        // A place that can't be read now (access revoked since the scan) is a locked cell; its old
        // scan numbers would count it twice.
        let unreadableNow = Set((input.places ?? []).filter { $0.access != .readable }.map(\.id))
        input.tiles = input.tiles.filter { !unreadableNow.contains($0.id) }
        let selected = Set(input.tiles.filter { $0.isSelected && !$0.stopped }.map(\.id))
        let finished: Bool
        var cleaned: Set<JunkCategoryID> = [], moving: Set<JunkCategoryID> = []
        switch input.phase {
        case .notScanned, .scanning: finished = false
        case .ready: finished = true
        case .moving: finished = true; moving = selected
        case .done: finished = true; cleaned = selected
        }
        let open = input.tiles.filter { !cleaned.contains($0.id) && $0.id != .trash }

        let trashBytes: UInt64?, trashLower: Bool
        switch input.trash {
        case .unknown: trashBytes = nil; trashLower = false
        case .read(let bytes, let skipped, let partial): trashBytes = bytes; trashLower = skipped || partial
        case .unreadable(let moved): trashBytes = moved; trashLower = true
        }

        let locked = lockedCells(
            places: input.places, trash: input.trash, scope: finished ? input.scanScope : nil)
        let lower = input.tiles.contains { $0.stopped } || locked > 0 || trashLower
        let reclaim = HomeMosaic.reclaimableBytes(tiles: input.tiles, excluding: cleaned, trashBytes: trashBytes)
        // Junk selected in a place that can't be read now is not offered: it may not be there.
        let selectedNow = input.selectedBytes.filter { !unreadableNow.contains($0.key) }.values.reduce(0, +)
        let safe = input.phase == .done ? 0 : selectedNow
        let after = input.available.map { available in
            finished ? available + Int64(clamping: safe + (trashBytes ?? 0)) : available
        }
        return HomeFigures(
            available: input.available,
            hero: input.available.map { HomeHero.make(available: $0, goal: input.goal) },
            scanFinished: finished,
            safeJunk: safe,
            reviewJunk: open.filter { $0.selection == .review }.reduce(0) { $0 + $1.bytes },
            trashBytes: trashBytes, trashIsLowerBound: trashLower,
            reclaimable: finished ? reclaim : nil, isLowerBound: lower,
            afterCleanup: after, afterCleanupIsLowerBound: finished && trashLower,
            lockedCells: locked,
            mosaic: HomeMosaic.layout(tiles: input.tiles, excluding: cleaned, trashBytes: trashBytes, lockedCells: locked),
            mosaicSummary: HomeMosaic.accessibilitySummary(
                reclaimable: reclaim, categories: open.filter { $0.bytes > 0 }.count, locked: locked),
            cleaned: cleaned, nibbling: moving, phase: input.phase)
    }

    /// One hatched cell per place Dustling couldn't read (locked or unreadable), per place the last
    /// scan covered only in part or not at all (it opened later), for an unreadable Trash in a place
    /// that reads as open, and for other volumes' Trash folders it didn't open.
    public static func lockedCells(places: [Place]?, trash: TrashReading, scope: HomeScanScope?) -> Int {
        let places = places ?? []
        var count = 0
        for place in places {
            if place.access != .readable { count += 1; continue }
            guard place.id != .trash, let scope else { continue }
            if !scope.full.contains(place.id) { count += 1 }
        }
        let trashPlaceOpen = places.first { $0.id == .trash }.map { $0.access == .readable } ?? true
        if trashPlaceOpen {
            switch trash {
            case .unreadable: count += 1
            case .read(_, let skipped, _) where skipped: count += 1
            default: break
            }
        }
        return count
    }
}
