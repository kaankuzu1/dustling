import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

private let gb: Int64 = 1_000_000_000
private let ugb: UInt64 = 1_000_000_000

struct GoalMeterTests {
    @Test func goalMeterHas45Segments() {
        let meter = GoalMeter.make(available: 10 * gb, afterCleanup: 20 * gb, needed: 30 * gb)
        #expect(meter.segments.count == 45)
        #expect(GoalMeter.segmentCount == 45)
    }

    @Test func segmentsSplitAvailableAndAfterCleanup() {
        // The mockup's numbers: 9.8 GB available, 40.28 GB after cleanup, update 21 GB.
        let meter = GoalMeter.make(available: 9_800_000_000, afterCleanup: 40_280_000_000, needed: 21 * gb)
        #expect(meter.segmentBytes == gb)
        #expect(meter.segments.prefix(10).allSatisfy { $0 == .available })
        #expect(meter.segments[10..<40].allSatisfy { $0 == .afterCleanup })
        #expect(meter.segments[40...].allSatisfy { $0 == .empty })
        #expect(abs(meter.markerFraction - 21.0 / 45.0) < 0.0001)
    }

    @Test func largeGoalScalesSegmentsSoTheMarkerFits() {
        let meter = GoalMeter.make(available: 0, afterCleanup: 0, needed: 90 * gb)
        #expect(meter.segmentBytes == 3 * gb)
        #expect(abs(meter.markerFraction - 90.0 / 135.0) < 0.0001)
        #expect(meter.segments.allSatisfy { $0 == .empty })
    }

    @Test func afterCleanupBelowAvailableAddsNothing() {
        let meter = GoalMeter.make(available: 5 * gb, afterCleanup: 2 * gb, needed: 30 * gb)
        #expect(meter.segments.filter { $0 == .available }.count == 5)
        #expect(!meter.segments.contains(.afterCleanup))
    }

    @Test func negativeNumbersAreClamped() {
        let meter = GoalMeter.make(available: -5 * gb, afterCleanup: -1, needed: -3)
        #expect(meter.segments.allSatisfy { $0 == .empty })
        #expect(meter.markerFraction == 0)
        #expect(meter.segmentBytes == gb)
    }
}

struct HomeHeroTests {
    @Test func shortfallGivesNeedMore() {
        let hero = HomeHero.make(available: 9 * gb, goal: UpdateGoal(neededBytes: 30 * gb))
        #expect(hero == .needMore(shortfall: 21 * gb))
        #expect(hero.headline == "You need 21 GB more for the macOS update")
    }

    @Test func noShortfallMeetsTheGoal() {
        let hero = HomeHero.make(available: 30 * gb, goal: UpdateGoal(neededBytes: 30 * gb))
        #expect(hero == .goalMet(available: 30 * gb))
        #expect(hero.headline == "Ready for the macOS update")
    }

    @Test func junkCaptionSaysEnoughOnlyWhenItIs() {
        let enough = HomeHero.junkCaption(safeJunk: 31_500_000_000, shortfall: 21 * gb)
        #expect(enough?.bold == "31.5 GB")
        #expect(enough?.rest == " of safe junk is ready to go, enough on its own.")
        let short = HomeHero.junkCaption(safeJunk: 4 * ugb, shortfall: 21 * gb)
        #expect(short?.rest == " of safe junk is ready to go.")
        #expect(HomeHero.junkCaption(safeJunk: 0, shortfall: 21 * gb) == nil)
    }

    @Test func goalMetCaptionNamesAvailableAndNeeded() {
        let caption = HomeHero.goalMetCaption(available: 43_350_000_000, needed: 21 * gb)
        #expect(caption.bold == "43.35 GB")
        #expect(caption.rest == " available. The update needs 21 GB.")
    }
}

struct PurgeableNoticeTests {
    private func storage(purgeable: Int64, snapshots: Int) -> StorageInfo {
        StorageInfo(
            totalBytes: 500 * gb, availableForImportantUsage: 20 * gb + purgeable,
            availableBytes: 20 * gb, localSnapshotCount: snapshots)
    }

    @Test func hiddenBelowTwoGigabytes() {
        #expect(PurgeableNotice.make(storage: storage(purgeable: 1_999_999_999, snapshots: 3)) == nil)
        #expect(PurgeableNotice.make(storage: nil) == nil)
    }

    @Test func shownFromTwoGigabytesWithPlainWords() throws {
        let notice = try #require(PurgeableNotice.make(storage: storage(purgeable: 4_200_000_000, snapshots: 0)))
        #expect(notice.title == "4.2 GB is purgeable.")
        #expect(notice.message == "macOS frees this space by itself when it needs room, so Dustling leaves it alone. "
            + "That's also why space from emptying the Trash can take a moment to show up.")
    }

    @Test func snapshotsAreNamedWhenThereAreAny() throws {
        let one = try #require(PurgeableNotice.make(storage: storage(purgeable: 2 * gb, snapshots: 1)))
        #expect(one.title == "2 GB is purgeable, including space held by 1 local Time Machine snapshot.")
        let many = try #require(PurgeableNotice.make(storage: storage(purgeable: 6 * gb, snapshots: 4)))
        #expect(many.title == "6 GB is purgeable, including space held by 4 local Time Machine snapshots.")
    }
}

struct HomeLinkTests {
    @Test func cellsMapToTheirTool() {
        #expect(HomeLink.link(for: .category(.userCaches)) == .junk)
        #expect(HomeLink.link(for: .inTrash) == .trash)
        #expect(HomeLink.link(for: .locked) == nil)
        #expect(HomeLink.link(for: .free) == nil)
        #expect(HomeLink.link(for: .other) == nil)
    }

    @Test func hoverDimsEveryOtherCellTo28Percent() {
        #expect(HomeLink.cellOpacity(.category(.xcodeJunk), hovered: nil) == 1)
        #expect(HomeLink.cellOpacity(.category(.xcodeJunk), hovered: .junk) == 1)
        #expect(HomeLink.cellOpacity(.inTrash, hovered: .junk) == 0.28)
        #expect(HomeLink.cellOpacity(.locked, hovered: .trash) == 0.28)
        #expect(HomeLink.cellOpacity(.inTrash, hovered: .trash) == 1)
    }
}

struct NibbleTests {
    @Test func cellsShrinkToFortyPercentAndFade() {
        let start = Nibble.cell(order: 0, elapsed: 0, reduceMotion: false)
        #expect(start.scale == 1 && start.opacity == 1)
        let end = Nibble.cell(order: 0, elapsed: Nibble.duration, reduceMotion: false)
        #expect(abs(end.scale - 0.4) < 0.0001 && end.opacity == 0)
    }

    @Test func staggerIsSevenMillisecondsCappedAt420() {
        // Cell 10 starts 70 ms in; cell 1000 starts at the 420 ms cap.
        #expect(Nibble.cell(order: 10, elapsed: 0.069, reduceMotion: false).opacity == 1)
        #expect(Nibble.cell(order: 10, elapsed: 0.071, reduceMotion: false).opacity < 1)
        #expect(Nibble.cell(order: 1000, elapsed: 0.419, reduceMotion: false).opacity == 1)
        #expect(Nibble.cell(order: 1000, elapsed: 0.421, reduceMotion: false).opacity < 1)
        #expect(Nibble.totalDuration(cells: 1000) == 0.42 + Nibble.duration)
    }

    @Test func reduceMotionRemovesCellsInstantly() {
        let cell = Nibble.cell(order: 50, elapsed: 0, reduceMotion: true)
        #expect(cell.opacity == 0)
        #expect(Nibble.totalDuration(cells: 50, reduceMotion: true) == 0)
    }
}

struct ToolCardsTests {
    @Test func junkCardSaysEnoughForTheUpdateWhenItIs() {
        let card = ToolCards.junk(safeBytes: 31_500_000_000, reviewBytes: 12_630_000_000, shortfall: 11 * gb)
        #expect(card.figure == "31.5 GB")
        #expect(card.line == "Enough for the update on its own")
    }

    @Test func junkCardMentionsReviewOtherwise() {
        let card = ToolCards.junk(safeBytes: 3 * ugb, reviewBytes: 12_630_000_000, shortfall: 11 * gb)
        #expect(card.line == "safe to remove, plus 12.63 GB to review")
        #expect(ToolCards.junk(safeBytes: 3 * ugb, reviewBytes: 0, shortfall: 0).line == "safe to remove")
        #expect(ToolCards.junk(safeBytes: 0, reviewBytes: 0, shortfall: 5 * gb, allClean: true).line == "All clean")
        // Nothing ticked is not the same as nothing found.
        #expect(ToolCards.junk(safeBytes: 0, reviewBytes: 0, shortfall: 5 * gb).line == "safe to remove")
    }

    private func app(_ name: String, lastUsed: Date?) -> InstalledApp {
        InstalledApp(
            url: URL(filePath: "/Applications/\(name).app"), displayName: name, bundleID: "com.example.\(name)",
            teamID: nil, executableName: nil, steamAppID: nil, bytes: 0, lastUsed: lastUsed)
    }

    private func row(_ app: InstalledApp, leftovers: Int, bytes: UInt64) -> AppRow {
        AppRow(app: app, isCounting: false, leftoverCount: leftovers, totalBytes: bytes, label: nil, warning: nil)
    }

    @Test func uninstallerCardCountsAppsWithLeftoversAndUnusedApps() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-91 * 86_400)
        let rows = [
            row(app("A", lastUsed: old), leftovers: 3, bytes: 20 * ugb),
            row(app("B", lastUsed: now), leftovers: 1, bytes: 18_420_000_000),
            row(app("C", lastUsed: old), leftovers: 0, bytes: 5 * ugb),
            row(app("D", lastUsed: nil), leftovers: 0, bytes: 1 * ugb),
        ]
        let card = ToolCards.uninstaller(rows, now: now)
        #expect(card.figure == "38.42 GB")
        #expect(card.line == "2 apps with leftovers, 2 not opened in 90 days")
    }

    @Test func uninstallerCardSingularAndNoUnused() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let card = ToolCards.uninstaller([row(app("A", lastUsed: now), leftovers: 2, bytes: ugb)], now: now)
        #expect(card.line == "1 app with leftovers")
    }

    private func item(_ label: String, on: Bool) -> StartupItem {
        StartupItem(
            label: label, scope: .userAgent, plistURL: nil, program: nil, ownerAppName: nil, isEnabled: on,
            managedInSystemSettingsOnly: false)
    }

    @Test func startupCardCountsOnItemsAndOrphans() {
        let items = [item("a", on: true), item("b", on: true), item("c", on: false)]
        #expect(ToolCards.startup(items, orphanCount: 1) == ToolCardText(figure: "2 on", line: "1 belongs to an app you removed"))
        #expect(ToolCards.startup(items, orphanCount: 2).line == "2 belong to apps you removed")
        #expect(ToolCards.startup(items, orphanCount: 0).line == "Nothing to review")
    }
}

struct ScanAgeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func agesReadPlainly() {
        #expect(ScanAge.text(since: now.addingTimeInterval(-20), now: now) == "just now")
        #expect(ScanAge.text(since: now.addingTimeInterval(-60), now: now) == "1 minute ago")
        #expect(ScanAge.text(since: now.addingTimeInterval(-150), now: now) == "2 minutes ago")
        #expect(ScanAge.text(since: now.addingTimeInterval(-3_600), now: now) == "1 hour ago")
        #expect(ScanAge.text(since: now.addingTimeInterval(-3 * 86_400), now: now) == "3 days ago")
        #expect(ScanAge.text(since: now.addingTimeInterval(30), now: now) == "just now")
    }
}

private func tile(
    _ id: JunkCategoryID, _ bytes: UInt64, selected: Bool = true, stopped: Bool = false,
    selection: Selection = .preselected
) -> CategoryTileModel {
    CategoryTileModel(
        id: id, title: "\(id)", note: nil, bytes: bytes, itemCount: 1, selection: selection,
        isSelected: selected, stopped: stopped, issues: [], inUseCount: 0, leftAlone: id.isNeverCleaned)
}

private let quarter: UInt64 = 268_435_456

struct HomeMosaicTests {
    @Test func reclaimableMosaicHasNoFreeOrOtherCells() {
        let layout = HomeMosaic.layout(
            tiles: [tile(.userCaches, 2 * quarter), tile(.xcodeJunk, 3 * quarter)],
            excluding: [], trashBytes: quarter, lockedCells: 1)
        #expect(layout.cells == [
            .category(.xcodeJunk), .category(.xcodeJunk), .category(.xcodeJunk),
            .category(.userCaches), .category(.userCaches), .inTrash, .locked,
        ])
        #expect(layout.rows == 4)
    }

    @Test func cleanedCategoriesLeaveTheMosaic() {
        let layout = HomeMosaic.layout(
            tiles: [tile(.userCaches, quarter), tile(.userLogs, quarter)], excluding: [.userCaches],
            trashBytes: 0, lockedCells: 0)
        #expect(layout.cells == [.category(.userLogs)])
        #expect(HomeMosaic.reclaimableBytes(
            tiles: [tile(.userCaches, quarter), tile(.userLogs, quarter)], excluding: [.userCaches], trashBytes: 5)
            == quarter + 5)
    }

    @Test func onlyReadablePlacesAreScannedAndNeverTheTrash() throws {
        let rig = try ModelRig()
        let catalog = JunkCatalog.standard(rig.environment, options: rig.options)
        let places = catalog.map { Place(id: $0.id, access: [.userLogs, .trash].contains($0.id) ? .readable : .locked) }
        #expect(HomeMosaic.scannable(catalog, places: places).map(\.id) == [.userLogs])
        #expect(HomeMosaic.scannable(catalog, places: nil).isEmpty)
        let unreadable = catalog.map { Place(id: $0.id, access: $0.id == .userLogs ? .unreadable : .readable) }
        #expect(!HomeMosaic.scannable(catalog, places: unreadable).map(\.id).contains(.userLogs))
    }

    @Test func appCachesWithoutContainersScanOnlyTheirPlainRoots() throws {
        let rig = try ModelRig()
        let catalog = JunkCatalog.standard(rig.environment, options: rig.options)
        let places = [Place(id: .userCaches, access: .readable, lockedExpansions: true)]
        let scanned = try #require(HomeMosaic.scannable(catalog, places: places).first)
        #expect(scanned.id == .userCaches && scanned.expansions.isEmpty)
    }

    @Test func systemCachesAndLogsAreNeverReclaimable() {
        // Dustling never cleans what macOS manages: its size is shown on the Junk scan, never as a cell
        // or as space Dustling could reclaim.
        let tiles = [tile(.userCaches, 2 * quarter), tile(.systemCachesAndLogs, 3 * quarter, selected: false)]
        let layout = HomeMosaic.layout(tiles: tiles, excluding: [], trashBytes: quarter, lockedCells: 0)
        #expect(layout.cells == [.category(.userCaches), .category(.userCaches), .inTrash])
        #expect(HomeMosaic.reclaimableBytes(tiles: tiles, excluding: [], trashBytes: quarter) == 3 * quarter)
        // Even when it is the only place holding anything.
        let only = [tile(.systemCachesAndLogs, 24 * quarter, selected: false)]
        #expect(HomeMosaic.layout(tiles: only, excluding: [], trashBytes: 0, lockedCells: 0).cells.isEmpty)
        #expect(HomeMosaic.reclaimableBytes(tiles: only, excluding: [], trashBytes: 0) == 0)
    }

    @Test func accessibilitySummaryReadsAsOneSentence() {
        #expect(HomeMosaic.accessibilitySummary(reclaimable: 15 * UInt64(gb), categories: 6, locked: 5)
            == "Reclaimable: 15 GB in 6 categories; 5 places locked")
        #expect(HomeMosaic.accessibilitySummary(reclaimable: UInt64(gb), categories: 1, locked: 0)
            == "Reclaimable: 1 GB in 1 category")
    }
}

struct HomeScanScopeTests {
    @Test func scopeGrowsWhenAPlaceOpensOrAContainerPartUnlocks() {
        let limited = [
            Place(id: .userLogs, access: .readable), Place(id: .xcodeJunk, access: .locked),
            Place(id: .userCaches, access: .readable, lockedExpansions: true), Place(id: .trash, access: .locked),
        ]
        let scope = HomeScanScope.make(places: limited)
        #expect(scope == HomeScanScope(full: [.userLogs], partial: [.userCaches]))
        #expect(!scope.isOutgrown(by: limited))
        let granted = [
            Place(id: .userLogs, access: .readable), Place(id: .xcodeJunk, access: .readable),
            Place(id: .userCaches, access: .readable), Place(id: .trash, access: .readable),
        ]
        #expect(scope.isOutgrown(by: granted))
        #expect(scope.isOutgrown(by: [Place(id: .userCaches, access: .readable)]))
        // Losing access never asks for a rescan.
        #expect(!HomeScanScope.make(places: granted).isOutgrown(by: limited))
    }

    @Test func rescanOnlyWhileTheJunkModelIsAtRest() {
        let scope = HomeScanScope(full: [.userLogs])
        let opened = [Place(id: .userLogs, access: .readable), Place(id: .xcodeJunk, access: .readable)]
        #expect(scope.shouldRescan(places: opened, phase: .ready))
        #expect(scope.shouldRescan(places: opened, phase: .notScanned))
        #expect(!scope.shouldRescan(places: opened, phase: .scanning))
        #expect(!scope.shouldRescan(places: opened, phase: .moving))
        #expect(!scope.shouldRescan(places: opened, phase: .done))
        #expect(!scope.shouldRescan(places: [Place(id: .userLogs, access: .readable)], phase: .ready))
    }
}

struct HomeFiguresTests {
    private func input(
        phase: HomeFigures.Phase = .ready, tiles: [CategoryTileModel] = [], selected: [JunkCategoryID: UInt64] = [:],
        trash: HomeFigures.TrashReading = .read(bytes: 0, externalSkipped: false), places: [Place]? = [],
        scope: HomeScanScope? = HomeScanScope(), available: Int64? = 10 * gb
    ) -> HomeFigures.Input {
        HomeFigures.Input(
            available: available, goal: UpdateGoal(neededBytes: 30 * gb), phase: phase, tiles: tiles,
            selectedBytes: selected, trash: trash, places: places, scanScope: scope)
    }

    @Test func readyCountsSafeJunkAndTrashInTheMeter() {
        let figures = HomeFigures.make(input(
            tiles: [tile(.userLogs, quarter), tile(.iosBackups, 2 * quarter, selected: false, selection: .review)],
            selected: [.userLogs: quarter], trash: .read(bytes: 1000, externalSkipped: false),
            places: [Place(id: .userLogs, access: .readable), Place(id: .iosBackups, access: .readable)],
            scope: HomeScanScope(full: [.userLogs, .iosBackups])))
        #expect(figures.safeJunk == quarter)
        #expect(figures.reviewJunk == 2 * quarter)
        #expect(figures.afterCleanup == 10 * gb + Int64(quarter) + 1000)
        #expect(!figures.isLowerBound && !figures.afterCleanupIsLowerBound)
        #expect(figures.reclaimable == 3 * quarter + 1000)
        #expect(figures.shortfall == 20 * gb)
    }

    @Test func movingNibblesSelectedAndDoneMovesThemToTheTrash() {
        let tiles = [tile(.userLogs, quarter), tile(.userCaches, quarter, selected: false), tile(.xcodeJunk, quarter, stopped: true)]
        let moving = HomeFigures.make(input(phase: .moving, tiles: tiles, selected: [.userLogs: quarter]))
        #expect(moving.nibbling == [.userLogs])
        #expect(moving.cleaned.isEmpty)
        let done = HomeFigures.make(input(phase: .done, tiles: tiles, selected: [.userLogs: quarter]))
        #expect(done.cleaned == [.userLogs])
        #expect(done.nibbling.isEmpty)
        #expect(done.safeJunk == 0)
        #expect(!done.mosaic.cells.contains(.category(.userLogs)))
        #expect(done.isLowerBound)   // the stopped tile
    }

    @Test func systemCachesAndLogsAreLeftOutOfEveryFigure() {
        let places = [
            Place(id: .userLogs, access: .readable), Place(id: .systemCachesAndLogs, access: .readable),
        ]
        let figures = HomeFigures.make(input(
            tiles: [tile(.userLogs, quarter), tile(.systemCachesAndLogs, 24 * quarter, selected: false)],
            selected: [.userLogs: quarter], trash: .read(bytes: 1000, externalSkipped: false), places: places,
            scope: HomeScanScope(full: [.userLogs, .systemCachesAndLogs])))
        #expect(figures.reclaimable == quarter + 1000)
        #expect(!figures.mosaic.cells.contains(.category(.systemCachesAndLogs)))
        #expect(figures.mosaicSummary == "Reclaimable: 268.4 MB in 1 category")
        #expect(figures.reviewJunk == 0)

        // Only System caches hold anything: nothing to reclaim, as the Junk scan's "All clean" says.
        let onlySystem = HomeFigures.make(input(
            tiles: [tile(.userLogs, 0), tile(.systemCachesAndLogs, 24 * quarter, selected: false)], places: places,
            scope: HomeScanScope(full: [.userLogs, .systemCachesAndLogs])))
        #expect(onlySystem.reclaimable == 0)
        #expect(onlySystem.mosaic.cells.isEmpty)
        #expect(onlySystem.mosaicSummary == "Reclaimable: 0 bytes in 0 categories")

        // A stopped scan of it, or a place of it Dustling can't read, hides nothing Dustling could free.
        let stopped = HomeFigures.make(input(
            tiles: [tile(.userLogs, quarter), tile(.systemCachesAndLogs, quarter, selected: false, stopped: true)],
            places: places, scope: HomeScanScope(full: [.userLogs, .systemCachesAndLogs])))
        #expect(!stopped.isLowerBound)
        let locked = HomeFigures.make(input(
            tiles: [tile(.userLogs, quarter)],
            places: [Place(id: .userLogs, access: .readable), Place(id: .systemCachesAndLogs, access: .unreadable)],
            scope: HomeScanScope(full: [.userLogs])))
        #expect(locked.lockedCells == 0)
        #expect(!locked.isLowerBound)
        #expect(locked.reclaimable == quarter)
    }

    @Test func notScannedYetHasNoTotals() {
        let figures = HomeFigures.make(input(phase: .scanning, selected: [.userLogs: quarter]))
        #expect(!figures.scanFinished)
        #expect(figures.reclaimable == nil)
        #expect(figures.afterCleanup == 10 * gb)
    }

    @Test func unreadableTrashShowsWhatDustlingMovedAsALowerBound() {
        let places = [Place(id: .trash, access: .locked)]
        let figures = HomeFigures.make(input(trash: .unreadable(movedSinceLastEmpty: 3 * quarter), places: places))
        #expect(figures.trashBytes == 3 * quarter)
        #expect(figures.trashIsLowerBound && figures.isLowerBound && figures.afterCleanupIsLowerBound)
        #expect(figures.mosaic.cells.filter { $0 == .inTrash }.count == 3)
        // The locked Trash place is one hatched cell, not two.
        #expect(figures.lockedCells == 1)
    }

    @Test func unreadableTrashInAnOpenPlaceAndSkippedVolumesAreLocked() {
        #expect(HomeFigures.lockedCells(
            places: [Place(id: .trash, access: .readable)], trash: .unreadable(movedSinceLastEmpty: 0), scope: nil) == 1)
        let skipped = HomeFigures.make(input(trash: .read(bytes: 10, externalSkipped: true), places: [Place(id: .trash, access: .readable)]))
        #expect(skipped.lockedCells == 1)
        #expect(skipped.trashIsLowerBound && skipped.isLowerBound)
    }

    @Test func systemItemsDustlingCantReadInsideMakeTheTrashALowerBoundWithoutALock() {
        // Nothing is locked: Empty Trash deletes them (with the password); only their size is unknown.
        let partial = HomeFigures.make(input(
            trash: .read(bytes: 10, externalSkipped: false, systemUnread: true), places: [Place(id: .trash, access: .readable)]))
        #expect(partial.trashBytes == 10)
        #expect(partial.trashIsLowerBound && partial.isLowerBound && partial.afterCleanupIsLowerBound)
        #expect(partial.lockedCells == 0)
    }

    @Test func placesThatOpenedAfterTheScanStayLockedUntilARescan() {
        // Scanned in limited mode; Full Disk Access arrived since.
        let scope = HomeScanScope(full: [.userLogs], partial: [.userCaches])
        let now = [
            Place(id: .userLogs, access: .readable), Place(id: .xcodeJunk, access: .readable),
            Place(id: .userCaches, access: .readable),
        ]
        let figures = HomeFigures.make(input(tiles: [tile(.userLogs, quarter), tile(.userCaches, quarter)], places: now, scope: scope))
        #expect(figures.lockedCells == 2)   // Xcode (not scanned) and the container part of app caches
        #expect(figures.isLowerBound)
        let rescanned = HomeFigures.make(input(places: now, scope: HomeScanScope.make(places: now)))
        #expect(rescanned.lockedCells == 0)
        #expect(!rescanned.isLowerBound)
    }

    @Test func lockedPlacesMakeTotalsALowerBound() {
        let figures = HomeFigures.make(input(places: [Place(id: .xcodeJunk, access: .locked)]))
        #expect(figures.lockedCells == 1)
        #expect(figures.isLowerBound)
    }

    @Test func revokedPlaceIsOnlyALockedCellNotItsOldBytes() {
        // Scanned with access; access was revoked since.
        let figures = HomeFigures.make(input(
            tiles: [tile(.userLogs, quarter), tile(.xcodeJunk, 4 * quarter)], selected: [:],
            places: [Place(id: .userLogs, access: .readable), Place(id: .xcodeJunk, access: .locked)],
            scope: HomeScanScope(full: [.userLogs, .xcodeJunk])))
        #expect(!figures.mosaic.cells.contains(.category(.xcodeJunk)))
        #expect(figures.mosaic.cells.filter { $0 == .locked }.count == 1)
        #expect(figures.reclaimable == quarter)
    }

    @Test func junkSelectedInARevokedPlaceIsLeftOutOfTheHeroAndMeter() {
        // Both were selected when access was on; Xcode data can't be read now.
        let figures = HomeFigures.make(input(
            tiles: [tile(.userLogs, quarter), tile(.xcodeJunk, 4 * quarter)],
            selected: [.userLogs: quarter, .xcodeJunk: 4 * quarter],
            places: [Place(id: .userLogs, access: .readable), Place(id: .xcodeJunk, access: .locked)],
            scope: HomeScanScope(full: [.userLogs, .xcodeJunk])))
        #expect(figures.safeJunk == quarter)
        #expect(figures.afterCleanup == 10 * gb + Int64(quarter))
    }
}

struct UnjudgedProgramFoldersTests {
    @Test func iCloudDriveConsentFoldersAndVolumesAreSkippedWithoutAccess() throws {
        let rig = try ModelRig()
        let folders = ProgramPresence.unjudgedFolders(rig.environment, fullDiskAccessGranted: false)
        #expect(folders.contains(rig.environment.userLibrary.appending(path: "Mobile Documents")))
        #expect(folders.contains(URL(filePath: "/Volumes")))
        #expect(folders.contains(rig.environment.home.appending(path: "Downloads")))
        let program = rig.environment.userLibrary.appending(path: "Mobile Documents/com~apple~CloudDocs/tool")
        #expect(!ProgramPresence.isOrphan(program.path(percentEncoded: false), unjudged: folders, presence: { _ in .missing }))
        #expect(ProgramPresence.unjudgedFolders(rig.environment, fullDiskAccessGranted: true).isEmpty)
    }
}

struct SidebarBadgesTests {
    private func figures(phase: HomeFigures.Phase, selected: UInt64) -> HomeFigures {
        HomeFigures.make(HomeFigures.Input(
            available: 10 * gb, goal: UpdateGoal(neededBytes: 30 * gb), phase: phase, tiles: [],
            selectedBytes: selected > 0 ? [.userLogs: selected] : [:], trash: .unknown, places: [], scanScope: nil))
    }

    @Test func junkShowsTheSelectionOnlyOnceAScanHasFinished() {
        #expect(SidebarBadges.junk(figures(phase: .ready, selected: 30_480_000_000)) == .init(text: "30.5 GB"))
        #expect(SidebarBadges.junk(figures(phase: .moving, selected: 2 * ugb)) == .init(text: "2 GB"))
        #expect(SidebarBadges.junk(figures(phase: .scanning, selected: 2 * ugb)) == nil)
        #expect(SidebarBadges.junk(figures(phase: .notScanned, selected: 0)) == nil)
        #expect(SidebarBadges.junk(figures(phase: .done, selected: 2 * ugb)) == nil)
        #expect(SidebarBadges.junk(figures(phase: .ready, selected: 0)) == nil)
    }

    private func row(leftovers: Int) -> AppRow {
        let app = InstalledApp(
            url: URL(filePath: "/Applications/A.app"), displayName: "A", bundleID: "com.example.a",
            teamID: nil, executableName: nil, steamAppID: nil, bytes: 0, lastUsed: nil)
        return AppRow(app: app, isCounting: false, leftoverCount: leftovers, totalBytes: 0, label: nil, warning: nil)
    }

    @Test func uninstallerCountsTheAppsItLists() {
        #expect(SidebarBadges.uninstaller(nil) == nil)
        #expect(SidebarBadges.uninstaller([]) == nil)
        #expect(SidebarBadges.uninstaller([row(leftovers: 0)]) == .init(text: "1 app"))
        #expect(SidebarBadges.uninstaller([row(leftovers: 2), row(leftovers: 0)]) == .init(text: "2 apps"))
    }

    @Test func startupFlagsOrphanedItems() {
        #expect(SidebarBadges.startup(orphanCount: nil) == nil)
        #expect(SidebarBadges.startup(orphanCount: 0) == nil)
        #expect(SidebarBadges.startup(orphanCount: 1) == .init(text: "1 to review", needsAttention: true))
    }
}
