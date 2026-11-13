import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

private let quarter: UInt64 = 268_435_456

private func tile(
    _ id: JunkCategoryID, _ bytes: UInt64, selected: Bool = true, stopped: Bool = false,
    selection: Selection = .preselected, items: Int = 3, inUse: Int = 0, needsHelper: Bool = false
) -> CategoryTileModel {
    CategoryTileModel(
        id: id, title: "\(id)", note: id == .iosBackups ? "Your data, never selected for you" : nil, bytes: bytes,
        itemCount: items, selection: selection, isSelected: selected, stopped: stopped, issues: [], inUseCount: inUse,
        needsHelper: needsHelper)
}

private let catalog: [JunkScreen.Entry] = [
    .init(id: .userCaches, title: "App caches", selection: .preselected),
    .init(id: .userLogs, title: "App logs", selection: .preselected),
    .init(id: .xcodeJunk, title: "Xcode data", selection: .preselected),
    .init(id: .systemCachesAndLogs, title: "System caches and logs", selection: .preselected),
    .init(id: .trash, title: "Trash", selection: .emptyTrashOnly),
    .init(id: .iosBackups, title: "iPhone and iPad backups", selection: .review),
    .init(id: .mailDownloads, title: "Mail downloads", selection: .review),
]

private func input(
    phase: JunkScreen.Phase = .ready, tiles: [CategoryTileModel], places: [Place]? = nil,
    scope: HomeScanScope? = nil, progress: [JunkCategoryID: CategoryProgress] = [:],
    outcomes: [JunkCategoryID: CategoryOutcome] = [:], fullDiskAccess: Bool = true
) -> JunkScreen.Input {
    let places = places ?? catalog.filter { $0.id != .trash }.map { Place(id: $0.id, access: .readable) }
    return JunkScreen.Input(
        catalog: catalog, phase: phase, tiles: tiles, places: places,
        scope: scope ?? HomeScanScope.make(places: places), progress: progress, outcomes: outcomes,
        fullDiskAccess: fullDiskAccess)
}

struct JunkScreenTilesTests {
    @Test func tilesFollowTheCatalogInTwoSectionsWithoutTheTrash() {
        let tiles = JunkScreen.tiles(input(tiles: [
            tile(.userCaches, quarter), tile(.userLogs, 0), tile(.xcodeJunk, 2 * quarter),
            tile(.systemCachesAndLogs, quarter, selected: false, needsHelper: true),
            tile(.iosBackups, quarter, selected: false, selection: .review),
            tile(.mailDownloads, 0, selected: false, selection: .review),
        ]))
        #expect(tiles.map(\.id) == [.userCaches, .userLogs, .xcodeJunk, .systemCachesAndLogs, .iosBackups, .mailDownloads])
        #expect(tiles.filter { $0.section == .safe }.count == 4)
        #expect(tiles.filter { $0.section == .review }.count == 2)
        #expect(tiles[0].status == .scanned && tiles[0].canToggle)
        #expect(tiles[3].status == .needsHelper && !tiles[3].canToggle)
        #expect(tiles[3].note == "Needs the cleanup helper (coming in a later version)")
        #expect(tiles[4].note == "Your data, never selected for you")
        #expect(tiles[5].note == "Review before removing")
        #expect(tiles[0].note == "3 items, rebuilt when needed")
    }

    @Test func emptyPlacesSayNothingIsThereAndTheScreenIsAllClean() {
        let empty = JunkScreen.tiles(input(tiles: [
            tile(.userCaches, 0, items: 0), tile(.userLogs, 0, items: 0), tile(.xcodeJunk, 0, items: 0),
            tile(.systemCachesAndLogs, quarter, selected: false, needsHelper: true),
            tile(.iosBackups, 0, selected: false, selection: .review, items: 0),
            tile(.mailDownloads, 0, selected: false, selection: .review, items: 0),
        ]))
        #expect(empty[0].note == JunkScreen.nothingFoundNote)
        #expect(empty[5].note == JunkScreen.nothingFoundNote)
        // The backups tile keeps its own note.
        #expect(empty[4].note == "Your data, never selected for you")
        #expect(JunkScreen.isAllClean(empty))

        let some = JunkScreen.tiles(input(tiles: [tile(.userCaches, 0, items: 0), tile(.userLogs, quarter)]))
        #expect(!JunkScreen.isAllClean(some))
        #expect(!JunkScreen.isAllClean([]))
        // Everything left out in Review files is still there: not "All clean".
        var leftOut = CategoryTileModel(
            id: .userCaches, title: "App caches", note: nil, bytes: quarter, itemCount: 2, selection: .preselected,
            isSelected: true, stopped: false, issues: [], inUseCount: 0, needsHelper: false)
        leftOut.excludedBytes = quarter
        leftOut.excludedCount = 2
        #expect(!JunkScreen.isAllClean(JunkScreen.tiles(input(tiles: [leftOut]))))
        // A stopped or locked place may hold something: never "All clean".
        let stopped = JunkScreen.tiles(input(tiles: [tile(.userCaches, 0, stopped: true, items: 0)]))
        #expect(!JunkScreen.isAllClean(stopped))
        #expect(JunkScreen.allCleanCaption(places: 11) == "Dustling checked 11 places and found nothing to move to the Trash.")
        #expect(JunkScreen.allCleanCaption(places: 1) == "Dustling checked 1 place and found nothing to move to the Trash.")
    }

    @Test func lockedPlacesAreLockedTilesNeverZeroBytes() {
        let places = [
            Place(id: .userCaches, access: .readable), Place(id: .xcodeJunk, access: .locked),
            Place(id: .mailDownloads, access: .unreadable),
        ]
        let tiles = JunkScreen.tiles(input(tiles: [tile(.userCaches, quarter)], places: places))
        let xcode = tiles.first { $0.id == .xcodeJunk }
        #expect(xcode?.status == .locked)
        #expect(xcode?.bytes == nil)
        #expect(xcode?.note == "Couldn't scan, needs Full Disk Access")
        #expect(xcode?.canToggle == false)
        #expect(xcode?.cells == MiniMosaic(count: 1, kind: .locked))
        let mail = tiles.first { $0.id == .mailDownloads }
        #expect(mail?.status == .unreadable)
        #expect(mail?.note == "Couldn't scan, Dustling can't open this folder")
    }

    @Test func stoppedTilesSayScanStoppedAndCountAsALowerBound() {
        let tiles = JunkScreen.tiles(input(tiles: [tile(.userCaches, quarter, selected: false, stopped: true)],
            places: [Place(id: .userCaches, access: .readable)]))
        #expect(tiles[0].status == .stopped)
        #expect(tiles[0].note == "Scan stopped, so there may be more")
        #expect(tiles[0].isLowerBound)
        #expect(!tiles[0].canToggle)
        let total = JunkScreen.sectionTotal(tiles, .safe)
        #expect(total.bytes == quarter && total.isLowerBound)
    }

    @Test func stoppedBeforeAnythingWasMeasuredIsUnknownNeverZero() {
        let tiles = JunkScreen.tiles(input(
            tiles: [tile(.userCaches, 0, selected: false, stopped: true, items: 0),
                    tile(.iosBackups, 0, selected: false, stopped: true, selection: .review, items: 0)],
            places: [Place(id: .userCaches, access: .readable), Place(id: .iosBackups, access: .readable)]))
        #expect(tiles[0].status == .stopped)
        #expect(tiles[0].bytes == nil)
        #expect(tiles[0].note == "Scan stopped before this place. Scan again to include it.")
        #expect(tiles[0].cells == MiniMosaic(count: 1, kind: .locked))
        let safe = JunkScreen.sectionTotal(tiles, .safe)
        #expect(safe.bytes == nil && safe.isLowerBound)
    }

    @Test func sectionTotalIsUnknownWhenNoTileHasASize() {
        let tiles = JunkScreen.tiles(input(
            tiles: [tile(.userCaches, quarter)],
            places: [Place(id: .userCaches, access: .readable), Place(id: .iosBackups, access: .locked),
                     Place(id: .mailDownloads, access: .locked)]))
        #expect(JunkScreen.sectionTotal(tiles, .review).bytes == nil)
        #expect(JunkScreen.sectionTotal(tiles, .safe).bytes == quarter)
    }

    @Test func placesThatOpenedAfterTheScanAreNotScannedYet() {
        let places = [Place(id: .userCaches, access: .readable), Place(id: .xcodeJunk, access: .readable)]
        let tiles = JunkScreen.tiles(input(
            tiles: [tile(.userCaches, quarter)], places: places, scope: HomeScanScope(full: [.userCaches])))
        let xcode = tiles.first { $0.id == .xcodeJunk }
        #expect(xcode?.status == .notScannedYet)
        #expect(xcode?.note == "Not scanned yet. Scan again to include it")
    }

    @Test func partlyScannedPlaceSaysSo() {
        let places = [Place(id: .userCaches, access: .readable, lockedExpansions: true)]
        let tiles = JunkScreen.tiles(input(tiles: [tile(.userCaches, quarter)], places: places))
        #expect(tiles[0].status == .scanned)
        #expect(tiles[0].isLowerBound)
        #expect(tiles[0].note == "3 items. App containers need Full Disk Access")
    }

    @Test func leftOutFilesShrinkTheTileAndAreNamedInTheNote() {
        var t = tile(.userCaches, 4 * quarter)
        t.excludedCount = 1
        t.excludedBytes = quarter
        let tiles = JunkScreen.tiles(input(tiles: [t], places: [Place(id: .userCaches, access: .readable)]))
        #expect(tiles[0].bytes == 3 * quarter)
        #expect(tiles[0].note == "3 items, 1 left out, rebuilt when needed")
        #expect(tiles[0].cells.count == 3)
    }

    @Test func leftOutIsNamedInEveryNote() {
        func note(_ t: CategoryTileModel, _ place: Place) -> String {
            var t = t
            t.excludedCount = 2
            return JunkScreen.tiles(input(tiles: [t], places: [place])).first { $0.id == t.id }?.note ?? ""
        }
        let readable = { (id: JunkCategoryID) in Place(id: id, access: .readable) }
        #expect(note(tile(.iosBackups, quarter, selection: .review), readable(.iosBackups))
            == "Your data, never selected for you, 2 left out")
        #expect(note(tile(.mailDownloads, quarter, selection: .review), readable(.mailDownloads))
            == "Review before removing, 2 left out")
        #expect(note(tile(.userCaches, quarter), Place(id: .userCaches, access: .readable, lockedExpansions: true))
            == "3 items, 2 left out. App containers need Full Disk Access")
        #expect(note(tile(.userCaches, quarter, inUse: 1), readable(.userCaches))
            == "3 items, 2 left out, 1 in use by open apps and left alone")
    }

    @Test func inUseItemsAreNamedInTheNote() {
        let tiles = JunkScreen.tiles(input(tiles: [tile(.userCaches, quarter, inUse: 2)],
            places: [Place(id: .userCaches, access: .readable)]))
        #expect(tiles[0].note == "3 items, 2 in use by open apps and left alone")
    }

    @Test func scanningShowsFinishedTilesAndSkeletonsForTheRest() {
        let tiles = JunkScreen.tiles(input(phase: .scanning, tiles: [tile(.userCaches, quarter)]))
        #expect(tiles.first { $0.id == .userCaches }?.status == .scanned)
        #expect(tiles.first { $0.id == .userLogs }?.status == .pending)
        #expect(tiles.allSatisfy { !$0.canToggle })
    }

    @Test func movingShowsEachSelectedTileQueuedMovingOrMoved() {
        let tiles = JunkScreen.tiles(input(
            phase: .moving,
            tiles: [tile(.userCaches, quarter), tile(.userLogs, quarter), tile(.xcodeJunk, quarter),
                    tile(.iosBackups, quarter, selected: false, selection: .review)],
            progress: [.userCaches: CategoryProgress(done: 4, total: 4), .userLogs: CategoryProgress(done: 1, total: 3),
                       .xcodeJunk: CategoryProgress(done: 0, total: 2)]))
        #expect(tiles.first { $0.id == .userCaches }?.status == .moved)
        #expect(tiles.first { $0.id == .userLogs }?.status == .moving)
        #expect(tiles.first { $0.id == .xcodeJunk }?.status == .queued)
        #expect(tiles.first { $0.id == .iosBackups }?.status == .scanned)
        #expect(tiles.allSatisfy { !$0.canToggle })
    }

    @Test func summaryShowsOnlyCleanedTilesWithWhatReallyMoved() {
        let outcome = CategoryOutcome(movedBytes: quarter / 2, movedCount: 1, skippedCount: 1, needsAdminCount: 1)
        let tiles = JunkScreen.tiles(input(
            phase: .done,
            tiles: [tile(.userCaches, quarter), tile(.userLogs, quarter, selected: false),
                    tile(.iosBackups, quarter, selected: false, selection: .review)],
            places: [Place(id: .userCaches, access: .readable), Place(id: .xcodeJunk, access: .locked)],
            outcomes: [.userCaches: outcome]))
        #expect(tiles.map(\.id) == [.userCaches])
        #expect(tiles[0].status == .cleaned)
        #expect(tiles[0].bytes == quarter / 2)
        #expect(tiles[0].note == "1 item in the Trash, 1 skipped, 1 needs your Mac password")
        #expect(tiles[0].cells == MiniMosaic(count: 1, kind: .inTrash))
        let limited = JunkScreen.tiles(input(
            phase: .done, tiles: [tile(.userCaches, quarter)], outcomes: [.userCaches: outcome], fullDiskAccess: false))
        #expect(limited[0].note == "1 item in the Trash, 1 skipped, 1 needs Full Disk Access, then your Mac password")

        // A ticked place that held nothing isn't listed as cleaned.
        let empty = JunkScreen.tiles(input(
            phase: .done, tiles: [tile(.userCaches, quarter), tile(.userLogs, 0, items: 0)],
            outcomes: [.userCaches: outcome]))
        #expect(empty.map(\.id) == [.userCaches])
    }

    @Test func putBackTilesSaySoAndLeaveTheTrash() {
        let all = CategoryOutcome(movedBytes: quarter, movedCount: 3, restoredCount: 3)
        let some = CategoryOutcome(movedBytes: quarter, movedCount: 3, skippedCount: 1, restoredCount: 2)
        let tiles = JunkScreen.tiles(input(
            phase: .done, tiles: [tile(.userCaches, quarter), tile(.userLogs, quarter)],
            outcomes: [.userCaches: all, .userLogs: some]))
        #expect(tiles[0].status == .putBack)
        #expect(tiles[0].note == "3 items put back")
        #expect(tiles[0].cells.kind == .selected)
        #expect(tiles[1].status == .cleaned)
        #expect(tiles[1].note == "2 put back, 1 still in the Trash, 1 skipped")
        #expect(tiles[1].cells.kind == .inTrash)
    }

    @Test func miniMosaicIsOneCellPerQuarterCappedAt60() {
        #expect(MiniMosaic.cells(bytes: 0) == 0)
        #expect(MiniMosaic.cells(bytes: 1) == 1)
        #expect(MiniMosaic.cells(bytes: 2 * quarter + 1) == 3)
        #expect(MiniMosaic.cells(bytes: 1000 * quarter) == 60)
        let off = JunkScreen.tiles(input(tiles: [tile(.userCaches, quarter, selected: false)],
            places: [Place(id: .userCaches, access: .readable)]))
        #expect(off[0].cells == MiniMosaic(count: 1, kind: .unselected))
    }

    @Test func selectionLineCountsWhatCanBeTicked() {
        let tiles = JunkScreen.tiles(input(tiles: [
            tile(.userCaches, quarter), tile(.userLogs, quarter, selected: false),
            tile(.systemCachesAndLogs, quarter, selected: false, needsHelper: true),
        ], places: [Place(id: .userCaches, access: .readable), Place(id: .userLogs, access: .readable),
                    Place(id: .systemCachesAndLogs, access: .readable), Place(id: .xcodeJunk, access: .locked)]))
        #expect(JunkScreen.selectionLine(tiles, selectedBytes: quarter) == "1 of 2 selected, 268.4 MB")
    }
}

struct JunkScreenTextTests {
    @Test func pathsUnderHomeAreShortened() {
        let home = URL(filePath: "/Users/k", directoryHint: .isDirectory)
        #expect(JunkScreen.displayPath(URL(filePath: "/Users/k/Library/Caches/x"), home: home) == "~/Library/Caches/x")
        #expect(JunkScreen.displayPath(URL(filePath: "/Library/Caches/x"), home: home) == "/Library/Caches/x")
    }

    @Test func scanLineNamesThePathAndPlacesDone() {
        let home = URL(filePath: "/Users/k", directoryHint: .isDirectory)
        let progress = ScanProgress(
            currentPath: URL(filePath: "/Users/k/Library/Caches/com.spotify.client"), bytesFound: 0,
            categoriesDone: 5, categoriesTotal: 9)
        #expect(JunkScreen.scanLine(progress, home: home) == "Checking ~/Library/Caches/com.spotify.client. 5 of 9 places done")
        let one = ScanProgress(currentPath: home, bytesFound: 0, categoriesDone: 0, categoriesTotal: 1)
        #expect(JunkScreen.scanLine(one, home: home) == "Checking ~. 0 of 1 place done")
        #expect(JunkScreen.scanPathLine(progress, home: home) == "Checking ~/Library/Caches/com.spotify.client.")
        #expect(JunkScreen.scanCountLine(progress) == "5 of 9 places done")
    }
}

struct JunkSummaryTests {
    private func record(_ entries: [JournalEntry]) -> RunRecord {
        RunRecord(startedAt: .now, kind: .junkClean, entries: entries, restorable: true, inProgress: false)
    }

    @Test func headlineAndSentenceComeFromOutcomesOnly() {
        let summary = JunkSummary.make(record([
            JournalEntry(originalPath: "/u/a", bytes: 100, outcome: .movedToTrash(trashedPath: "/t/a")),
            JournalEntry(originalPath: "/u/b", bytes: 200, outcome: .movedToTrash(trashedPath: "/t/b")),
            JournalEntry(originalPath: "/u/m1", bytes: 50, outcome: .skipped(reason: "in use by com.apple.mail")),
            JournalEntry(originalPath: "/u/m2", bytes: 50, outcome: .skipped(reason: "in use by com.apple.mail")),
            JournalEntry(originalPath: "/u/x", bytes: 70, outcome: .failed(reason: "disk exploded")),
        ]), appName: { $0 == "com.apple.mail" ? "Mail" : nil })
        #expect(summary.movedBytes == 300)
        #expect(summary.sentence == "2 items moved, 2 skipped, 1 failed.")
        #expect(summary.reasons.map(\.text) == ["2 skipped because Mail is using them", "1 failed: disk exploded"])
        #expect(summary.reasons[0].paths == ["/u/m1", "/u/m2"])
    }

    @Test func singularAndUnknownAppNames() {
        let summary = JunkSummary.make(record([
            JournalEntry(originalPath: "/u/a", bytes: 100, outcome: .movedToTrash(trashedPath: "/t/a")),
            JournalEntry(originalPath: "/u/b", bytes: 1, outcome: .skipped(reason: "in use by com.x.y")),
            JournalEntry(originalPath: "/u/c", bytes: 1, outcome: .skipped(reason: "cleanup stopped")),
            JournalEntry(originalPath: "/u/d", bytes: 1, outcome: .needsAdmin),
        ]), appName: { _ in nil })
        #expect(summary.sentence == "1 item moved, 2 skipped, 1 needs your Mac password.")
        #expect(summary.reasons.map(\.text) == [
            "1 skipped because com.x.y is using it", "1 skipped: cleanup stopped", "1 needs your Mac password",
        ])
        let limited = JunkSummary.make(record([
            JournalEntry(originalPath: "/u/d", bytes: 1, outcome: .needsAdmin),
            JournalEntry(originalPath: "/u/e", bytes: 1, outcome: .needsAdmin),
        ]), fullDiskAccess: false)
        #expect(limited.sentence == "0 items moved, 2 need Full Disk Access, then your Mac password.")
        #expect(limited.reasons.map(\.text) == ["2 need Full Disk Access, then your Mac password"])
    }

    @Test func restoreHeadlineFollowsWhatCameBack() {
        #expect(JunkSummary.restoreHeadline([.restored("/a")]) == "Everything was put back")
        #expect(JunkSummary.restoreHeadline([.restored("/a"), .conflict("/b")]) == "Some items were put back")
        #expect(JunkSummary.restoreHeadline([.failed("/a", reason: "x")]) == "Nothing was put back")
    }

    @Test func restoreLineSaysWhatCameBack() {
        #expect(JunkSummary.restoreLine([.restored("/a"), .restored("/b")]) == "2 items are back where they were.")
        #expect(JunkSummary.restoreLine([.restored("/a"), .conflict("/b"), .missingFromTrash("/c"), .failed("/d", reason: "nope")])
            == "1 item is back where it was. 3 couldn't go back: 1 because something new is in its place, "
            + "1 because it's no longer in the Trash, 1 failed: nope.")
    }

    @Test func outcomesAreSplitByCategory() {
        let rec = record([
            JournalEntry(originalPath: "/c/a", bytes: 100, outcome: .movedToTrash(trashedPath: "/t/a")),
            JournalEntry(originalPath: "/c/b", bytes: 5, outcome: .skipped(reason: "in use by x")),
            JournalEntry(originalPath: "/l/a", bytes: 7, outcome: .failed(reason: "no")),
            JournalEntry(originalPath: "<history>", bytes: 0, outcome: .failed(reason: "disk full")),
            JournalEntry(originalPath: "/l/b", bytes: 0, outcome: .needsAdmin),
        ])
        let outcomes = CategoryOutcome.split(
            rec, categoryOf: ["/c/a": .userCaches, "/c/b": .userCaches, "/l/a": .userLogs, "/l/b": .userLogs])
        #expect(outcomes[.userCaches] == CategoryOutcome(movedBytes: 100, movedCount: 1, skippedCount: 1, failedCount: 0))
        #expect(outcomes[.userLogs] == CategoryOutcome(failedCount: 1, needsAdminCount: 1))
        #expect(outcomes.count == 2)
    }
}

struct CountUpTests {
    @Test func countsUpWithACubicEaseOutAndJumpsUnderReduceMotion() {
        #expect(CountUp.value(1000, elapsed: 0, reduceMotion: false) == 0)
        #expect(CountUp.value(1000, elapsed: 0.45, reduceMotion: false) == 875)
        #expect(CountUp.value(1000, elapsed: 0.9, reduceMotion: false) == 1000)
        #expect(CountUp.value(1000, elapsed: 5, reduceMotion: false) == 1000)
        #expect(CountUp.value(1000, elapsed: 0, reduceMotion: true) == 1000)
    }
}

struct TrashListingTests {
    private func item(_ name: String, _ bytes: UInt64) -> TrashItem {
        TrashItem(url: URL(filePath: "/Users/k/.Trash/\(name)"), size: SizeResult(bytes: bytes))
    }

    @Test func largestFirstCappedAtFiftyWithTheRestCounted() {
        let items = (1...53).map { item("f\($0)", UInt64($0)) }
        let listing = TrashListing.make(items)
        #expect(listing.rows.count == 50)
        #expect(listing.rows.first?.name == "f53")
        #expect(listing.rows.last?.name == "f4")
        #expect(listing.more == 3)
        #expect(listing.moreLine == "…and 3 more")
    }

    @Test func noMoreLineWhenEverythingFits() {
        let listing = TrashListing.make([item("a", 2), item("b", 2)])
        #expect(listing.rows.map(\.name) == ["a", "b"])
        #expect(listing.moreLine == nil)
    }
}

struct JunkTileAccessibilityTests {
    private func tile(_ status: JunkTile.Status, bytes: UInt64?, lower: Bool = false, selected: Bool) -> JunkTile {
        JunkTile(
            id: .userCaches, title: "App caches", section: .safe, status: status, bytes: bytes,
            isLowerBound: lower, isSelected: selected, canToggle: status == .scanned, note: "note",
            cells: MiniMosaic(count: 1, kind: .selected))
    }

    @Test func tilesReadSizeAndSelection() {
        #expect(tile(.scanned, bytes: 4_200_000_000, selected: true).accessibilityValue == "4.2 GB, selected")
        #expect(tile(.scanned, bytes: 1_000_000, selected: false).accessibilityValue == "1 MB, not selected")
        #expect(tile(.stopped, bytes: 1_000_000, lower: true, selected: true).accessibilityValue
            == "1 MB or more, scan stopped, selected")
    }

    @Test func tilesWithoutASizeNeverReadZero() {
        let locked = tile(.locked, bytes: nil, selected: false).accessibilityValue
        #expect(locked == "size unknown, locked")
        #expect(!locked.contains("0"))
        #expect(tile(.needsHelper, bytes: 2_000_000, selected: false).accessibilityValue
            == "2 MB, needs the cleanup helper")
        #expect(tile(.pending, bytes: nil, selected: false).accessibilityValue == "scanning")
    }
}

