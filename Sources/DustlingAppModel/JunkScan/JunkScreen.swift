import DustlingCore
import Foundation

/// A tile's mini mosaic (SCREENS-final §3): one cell per quarter gigabyte, at most 60.
public struct MiniMosaic: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Full category colour: selected.
        case selected
        /// The category colour mixed 22% into `panel`: not selected (or can't be).
        case unselected
        /// Hatched: moved to the Trash, not freed until Empty Trash.
        case inTrash
        /// Hatched in `line` over `panel`: a place Dustling couldn't read.
        case locked
    }

    public static let maxCells = 60
    public let count: Int
    public let kind: Kind

    public init(count: Int, kind: Kind) {
        self.count = count
        self.kind = kind
    }

    /// Ceiling, like the storage mosaic: any bytes at all get a cell; no bytes get none.
    public static func cells(bytes: UInt64, cellBytes: UInt64 = 268_435_456) -> Int {
        let (q, r) = bytes.quotientAndRemainder(dividingBy: max(cellBytes, 1))
        return min(maxCells, Int(clamping: q) + (r > 0 ? 1 : 0))
    }
}

/// One tile of the Junk scan screen, worked out from the scan, the places check and the cleanup.
public struct JunkTile: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Scanning hasn't reached it yet: a skeleton.
        case pending
        /// Scanned in full (or as far as the place allows): checkbox, size and note.
        case scanned
        /// The scan was stopped in or before it.
        case stopped
        /// Its place needs Full Disk Access; never opened.
        case locked
        /// Its place can't be opened for another reason.
        case unreadable
        /// Its place opened after the last scan.
        case notScannedYet
        /// Only the cleanup helper could move it.
        case needsHelper
        /// Selected for the cleanup in progress, not started yet.
        case queued
        /// Its items are moving right now.
        case moving
        /// All its items have been attempted.
        case moved
        /// Summary: what the finished cleanup did here.
        case cleaned
    }

    public let id: JunkCategoryID
    public let title: String
    public let section: JunkScreen.Section
    public let status: Status
    /// nil when nothing is known (locked, unreadable, not scanned, pending). For `cleaned`, the moved bytes.
    public let bytes: UInt64?
    /// The size may be more than shown (stopped, or part of the place locked).
    public let isLowerBound: Bool
    public let isSelected: Bool
    public let canToggle: Bool
    public let note: String
    public let cells: MiniMosaic
    /// Review tiles are outlined (the mockup's `.tile2.off`).
    public var isOutlined: Bool { !isSelected && status != .cleaned }

    /// What VoiceOver reads after the tile's name: its size (or that it isn't known), then its state,
    /// e.g. "4.2 GB, selected" or "size unknown, locked". The note is read as the hint.
    public var accessibilityValue: String {
        let size: String
        if let bytes {
            size = Bytes.format(bytes) + (isLowerBound ? " or more" : "")
        } else {
            size = "size unknown"
        }
        let selection = isSelected ? "selected" : "not selected"
        let state: String
        switch status {
        case .pending: return "scanning"
        case .scanned: state = selection
        case .stopped: state = "scan stopped, \(selection)"
        case .locked: state = "locked"
        case .unreadable: state = "can't be read"
        case .notScannedYet: state = "not scanned yet"
        case .needsHelper: state = "needs the cleanup helper"
        case .queued: state = "waiting to move"
        case .moving: state = "moving to the Trash"
        case .moved: state = "done"
        case .cleaned: state = "moved to the Trash"
        }
        return "\(size), \(state)"
    }
}

/// The logic behind the Junk scan screen (SCREENS-final §3), kept out of the views so it can be tested.
public enum JunkScreen {
    public enum Section: Equatable, Sendable {
        /// "Safe to remove": preselected categories.
        case safe
        /// "Review first": unchecked categories, then the Trash tile.
        case review
    }

    public enum Phase: Equatable, Sendable { case notScanned, scanning, ready, moving, done }

    /// One category of the catalog, as named on screen.
    public struct Entry: Equatable, Sendable {
        public let id: JunkCategoryID
        public let title: String
        public let selection: Selection

        public init(id: JunkCategoryID, title: String, selection: Selection) {
            self.id = id
            self.title = title
            self.selection = selection
        }
    }

    public struct Input: Sendable {
        public var catalog: [Entry]
        public var phase: Phase
        public var tiles: [CategoryTileModel]
        public var places: [Place]?
        /// What the last scan covered; nil before one.
        public var scope: HomeScanScope?
        public var progress: [JunkCategoryID: CategoryProgress]
        public var outcomes: [JunkCategoryID: CategoryOutcome]

        public init(
            catalog: [Entry], phase: Phase, tiles: [CategoryTileModel], places: [Place]?, scope: HomeScanScope?,
            progress: [JunkCategoryID: CategoryProgress], outcomes: [JunkCategoryID: CategoryOutcome]
        ) {
            self.catalog = catalog
            self.phase = phase
            self.tiles = tiles
            self.places = places
            self.scope = scope
            self.progress = progress
            self.outcomes = outcomes
        }
    }

    public static let helperNote = "Needs the cleanup helper (coming in a later version)"
    public static let lockedNote = "Couldn't scan, needs Full Disk Access"
    public static let unreadableNote = "Couldn't scan, Dustling can't open this folder"
    public static let notScannedNote = "Not scanned yet. Scan again to include it"
    public static let stoppedNote = "Scan stopped, so there may be more"
    public static let stoppedBeforeNote = "Scan stopped before this place. Scan again to include it."

    /// The tiles in catalog order. The Trash is never a tile here: the screen draws it from `TrashModel`.
    /// The summary shows only the categories the cleanup worked on.
    public static func tiles(_ input: Input) -> [JunkTile] {
        let byID = Dictionary(input.tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let places = Dictionary((input.places ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // During a cleanup the first unfinished category is the one moving; the later ones wait.
        let movingID = input.phase == .moving
            ? input.catalog.first { entry in
                guard let tile = byID[entry.id], tile.isSelected, !tile.stopped else { return false }
                return !(input.progress[entry.id]?.isFinished ?? true)
            }?.id
            : nil

        return input.catalog.compactMap { entry -> JunkTile? in
            guard entry.id != .trash, let section = section(for: entry.selection) else { return nil }
            let place = places[entry.id]
            let tile = byID[entry.id]

            if input.phase == .done {
                guard let tile, tile.isSelected, !tile.stopped else { return nil }
                let outcome = input.outcomes[entry.id] ?? CategoryOutcome()
                return JunkTile(
                    id: entry.id, title: entry.title, section: section, status: .cleaned, bytes: outcome.movedBytes,
                    isLowerBound: false, isSelected: true, canToggle: false, note: cleanedNote(outcome),
                    cells: MiniMosaic(count: MiniMosaic.cells(bytes: outcome.movedBytes), kind: .inTrash))
            }

            func make(_ status: JunkTile.Status, bytes: UInt64? = nil, lower: Bool = false, selected: Bool = false,
                      toggle: Bool = false, note: String, cells: MiniMosaic) -> JunkTile {
                JunkTile(
                    id: entry.id, title: entry.title, section: section, status: status, bytes: bytes,
                    isLowerBound: lower, isSelected: selected, canToggle: toggle, note: note, cells: cells)
            }
            let lockedCell = MiniMosaic(count: 1, kind: .locked)

            switch place?.access {
            case .locked: return make(.locked, note: lockedNote, cells: lockedCell)
            case .unreadable: return make(.unreadable, note: unreadableNote, cells: lockedCell)
            case .readable, nil: break
            }

            guard let tile else {
                if input.phase == .scanning || input.phase == .notScanned {
                    return make(.pending, note: "", cells: MiniMosaic(count: 0, kind: .unselected))
                }
                return make(.notScannedYet, note: notScannedNote, cells: lockedCell)
            }

            let partial = place?.lockedExpansions == true && input.scope?.partial.contains(entry.id) == true
            // Files left out in Review files don't count toward the tile.
            let shownBytes = tile.bytes - min(tile.bytes, tile.excludedBytes)
            let cells = MiniMosaic(count: MiniMosaic.cells(bytes: shownBytes), kind: tile.isSelected ? .selected : .unselected)
            if tile.stopped {
                // Stopped before anything here was measured: unknown, never 0 bytes.
                if tile.itemCount == 0 && tile.bytes == 0 {
                    return make(.stopped, lower: true, note: stoppedBeforeNote, cells: lockedCell)
                }
                return make(.stopped, bytes: tile.bytes, lower: true, note: stoppedNote, cells: cells)
            }
            if tile.needsHelper {
                return make(.needsHelper, bytes: tile.bytes, note: helperNote, cells: cells)
            }
            var status = JunkTile.Status.scanned
            if input.phase == .moving, tile.isSelected {
                if input.progress[entry.id]?.isFinished ?? true {
                    status = .moved
                } else {
                    status = entry.id == movingID ? .moving : .queued
                }
            }
            return make(
                status, bytes: shownBytes, lower: partial, selected: tile.isSelected,
                toggle: input.phase == .ready, note: scannedNote(tile, selection: entry.selection, partial: partial),
                cells: cells)
        }
    }

    static func section(for selection: Selection) -> Section? {
        switch selection {
        case .preselected: .safe
        case .review: .review
        case .emptyTrashOnly: nil
        }
    }

    private static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    private static func scannedNote(_ tile: CategoryTileModel, selection: Selection, partial: Bool) -> String {
        let leftOut = tile.excludedCount > 0 ? ", \(tile.excludedCount) left out" : ""
        if let note = tile.note { return note + leftOut }
        if selection == .review { return "Review before removing" + leftOut }
        if partial { return "\(items(tile.itemCount))\(leftOut). App containers need Full Disk Access" }
        if tile.inUseCount > 0 {
            return "\(items(tile.itemCount))\(leftOut), \(tile.inUseCount) in use by open apps and left alone"
        }
        return "\(items(tile.itemCount))\(leftOut), rebuilt when needed"
    }

    private static func cleanedNote(_ outcome: CategoryOutcome) -> String {
        var parts = ["\(items(outcome.movedCount)) in the Trash"]
        if outcome.skippedCount > 0 { parts.append("\(outcome.skippedCount) skipped") }
        if outcome.failedCount > 0 { parts.append("\(outcome.failedCount) failed") }
        if outcome.needsAdminCount > 0 {
            parts.append("\(outcome.needsAdminCount) \(outcome.needsAdminCount == 1 ? "needs" : "need") the cleanup helper")
        }
        return parts.joined(separator: ", ")
    }

    /// A section's size: what its tiles hold (or, in the summary, what moved), "or more" when any tile
    /// is partial or wasn't read. nil when no tile in the section has a known size.
    public static func sectionTotal(_ tiles: [JunkTile], _ section: Section) -> (bytes: UInt64?, isLowerBound: Bool) {
        let mine = tiles.filter { $0.section == section }
        let known = mine.compactMap(\.bytes)
        let bytes: UInt64? = known.isEmpty ? nil : known.reduce(0, +)
        let lower = mine.contains {
            $0.isLowerBound || [.locked, .unreadable, .notScannedYet, .pending].contains($0.status)
        }
        return (bytes, lower)
    }

    /// The action bar's "6 of 9 selected, 31.5 GB".
    public static func selectionLine(_ tiles: [JunkTile], selectedBytes: UInt64) -> String {
        let choosable = tiles.filter { $0.canToggle }
        let selected = choosable.filter(\.isSelected).count
        return "\(selected) of \(choosable.count) selected, \(Bytes.format(selectedBytes))"
    }

    /// `~/Library/Caches/x` for paths in the home folder.
    public static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        var base = home.standardizedFileURL.path(percentEncoded: false)
        if base.hasSuffix("/") { base.removeLast() }
        if path == base || path == base + "/" { return "~" }
        if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        return path
    }

    /// "Checking ~/Library/Caches/com.spotify.client. 5 of 9 places done".
    public static func scanLine(_ progress: ScanProgress, home: URL) -> String {
        let places = progress.categoriesTotal == 1 ? "place" : "places"
        return "Checking \(displayPath(progress.currentPath, home: home)). "
            + "\(progress.categoriesDone) of \(progress.categoriesTotal) \(places) done"
    }
}

/// The cleanup summary (SCREENS-final §3), read only from the run's recorded outcomes.
public struct JunkSummary: Equatable, Sendable {
    public struct Reason: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case skipped, failed, needsAdmin }
        public let kind: Kind
        public let text: String
        /// The original paths, in run order.
        public let paths: [String]
    }

    public let movedBytes: UInt64
    public let movedCount: Int
    /// "30,365 items moved, 2 skipped, 1 failed."
    public let sentence: String
    /// One line per distinct reason, in the order they first happened.
    public let reasons: [Reason]

    /// `appName` turns a bundle ID into the app's name, nil when unknown.
    public static func make(_ record: RunRecord, appName: (String) -> String? = { _ in nil }) -> JunkSummary {
        var moved = 0, skipped = 0, failed = 0, admin = 0
        var groups: [(kind: Reason.Kind, reason: String, paths: [String])] = []
        func add(_ kind: Reason.Kind, _ reason: String, _ path: String) {
            if let index = groups.firstIndex(where: { $0.kind == kind && $0.reason == reason }) {
                groups[index].paths.append(path)
            } else {
                groups.append((kind, reason, [path]))
            }
        }
        for entry in record.entries {
            switch entry.outcome {
            case .movedToTrash: moved += 1
            case .skipped(let reason): skipped += 1; add(.skipped, reason, entry.originalPath)
            case .failed(let reason): failed += 1; add(.failed, reason, entry.originalPath)
            case .needsAdmin: admin += 1; add(.needsAdmin, "", entry.originalPath)
            case .deleted: break
            }
        }
        var parts = [moved == 1 ? "1 item moved" : "\(moved.formatted(.number.locale(Locale(identifier: "en_US")))) items moved"]
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        if admin > 0 { parts.append("\(admin) \(admin == 1 ? "needs" : "need") the cleanup helper") }

        let reasons = groups.map { group -> Reason in
            let n = group.paths.count
            let text: String
            switch group.kind {
            case .skipped:
                let prefix = "in use by "
                if group.reason.hasPrefix(prefix) {
                    let id = String(group.reason.dropFirst(prefix.count))
                    text = "\(n) skipped because \(appName(id) ?? id) is using \(n == 1 ? "it" : "them")"
                } else {
                    text = "\(n) skipped: \(group.reason)"
                }
            case .failed: text = "\(n) failed: \(group.reason)"
            case .needsAdmin: text = "\(n) \(n == 1 ? "needs" : "need") the cleanup helper"
            }
            return Reason(kind: group.kind, text: text, paths: group.paths)
        }
        return JunkSummary(
            movedBytes: record.bytesMovedToTrash, movedCount: moved,
            sentence: parts.joined(separator: ", ") + ".", reasons: reasons)
    }

    /// The headline after Put everything back, from what really came back.
    public static func restoreHeadline(_ outcomes: [RestoreOutcome]) -> String {
        let restored = outcomes.filter { if case .restored = $0 { true } else { false } }.count
        if restored == 0 { return "Nothing was put back" }
        return restored == outcomes.count ? "Everything was put back" : "Some items were put back"
    }

    /// What Put everything back did, in one sentence.
    public static func restoreLine(_ outcomes: [RestoreOutcome]) -> String {
        var restored = 0, conflict = 0, missing = 0
        var failures: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .restored: restored += 1
            case .conflict: conflict += 1
            case .missingFromTrash: missing += 1
            case .failed(_, let reason): failures.append(reason)
            }
        }
        var text = restored == 1 ? "1 item is back where it was." : "\(restored) items are back where they were."
        let notBack = conflict + missing + failures.count
        guard notBack > 0 else { return text }
        var why: [String] = []
        if conflict > 0 { why.append("\(conflict) because something new is in its place") }
        if missing > 0 { why.append("\(missing) because it's no longer in the Trash") }
        var failedByReason: [(String, Int)] = []
        for reason in failures {
            if let index = failedByReason.firstIndex(where: { $0.0 == reason }) { failedByReason[index].1 += 1 }
            else { failedByReason.append((reason, 1)) }
        }
        why += failedByReason.map { "\($0.1) failed: \($0.0)" }
        text += " \(notBack) couldn't go back: " + why.joined(separator: ", ") + "."
        return text
    }
}

/// The summary's counted-up figure (DESIGN-mosaic §9): 0.9 s, cubic ease-out. Under Reduce Motion
/// the final value shows at once.
public enum CountUp {
    public static let duration = 0.9

    public static func value(_ target: UInt64, elapsed: Double, reduceMotion: Bool) -> UInt64 {
        guard !reduceMotion, elapsed < duration else { return target }
        let t = max(0, elapsed) / duration
        let eased = 1 - pow(1 - t, 3)
        return UInt64((Double(target) * eased).rounded())
    }
}

/// The Empty Trash sheet's list: the largest items first, at most 50, then "…and N more".
public struct TrashListing: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: URL { url }
        public let url: URL
        public let name: String
        public let bytes: UInt64
    }

    public static let cap = 50
    public let rows: [Row]
    public let more: Int

    public var moreLine: String? { more > 0 ? "…and \(more) more" : nil }

    public static func make(_ items: [TrashItem], cap: Int = TrashListing.cap) -> TrashListing {
        let sorted = items.sorted {
            $0.size.bytes != $1.size.bytes ? $0.size.bytes > $1.size.bytes : $0.url.path < $1.url.path
        }
        let rows = sorted.prefix(cap).map { Row(url: $0.url, name: $0.url.lastPathComponent, bytes: $0.size.bytes) }
        return TrashListing(rows: rows, more: max(0, sorted.count - cap))
    }
}
