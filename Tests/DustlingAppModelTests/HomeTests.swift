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
        #expect(notice.message == "macOS frees these by itself when it needs room, so Dustling leaves them alone. "
            + "That's also why emptying the Trash can take a moment to show up.")
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

struct HomeMosaicTests {
    private func tile(_ id: JunkCategoryID, _ bytes: UInt64, selected: Bool = true, stopped: Bool = false) -> CategoryTileModel {
        CategoryTileModel(
            id: id, title: "\(id)", note: nil, bytes: bytes, itemCount: 1, selection: .preselected,
            isSelected: selected, stopped: stopped, issues: [], inUseCount: 0)
    }

    private let quarter: UInt64 = 268_435_456

    @Test func reclaimableMosaicHasNoFreeOrOtherCells() {
        let places = [Place(id: .userCaches, access: .readable), Place(id: .trash, access: .readable)]
        let layout = HomeMosaic.layout(
            tiles: [tile(.userCaches, 2 * quarter), tile(.xcodeJunk, 3 * quarter)],
            excluding: [], trashBytes: quarter, places: places)
        #expect(layout.cells == [
            .category(.xcodeJunk), .category(.xcodeJunk), .category(.xcodeJunk),
            .category(.userCaches), .category(.userCaches), .inTrash,
        ])
        #expect(layout.rows == 4)
    }

    @Test func lockedAndUnreadablePlacesAreHatchedNeverZero() {
        let places = [
            Place(id: .userCaches, access: .readable), Place(id: .xcodeJunk, access: .locked),
            Place(id: .userLogs, access: .unreadable), Place(id: .trash, access: .locked),
        ]
        let layout = HomeMosaic.layout(tiles: [tile(.userCaches, quarter)], excluding: [], trashBytes: nil, places: places)
        #expect(layout.cells.filter { $0 == .locked }.count == 3)
        #expect(!layout.cells.contains(.inTrash))
    }

    @Test func unreadableTrashInAReadablePlaceStillShowsLocked() {
        let places = [Place(id: .trash, access: .readable)]
        let layout = HomeMosaic.layout(tiles: [], excluding: [], trashBytes: nil, places: places)
        #expect(layout.cells == [.locked])
    }

    @Test func cleanedCategoriesLeaveTheMosaic() {
        let layout = HomeMosaic.layout(
            tiles: [tile(.userCaches, quarter), tile(.userLogs, quarter)], excluding: [.userCaches],
            trashBytes: 0, places: [])
        #expect(layout.cells == [.category(.userLogs)])
        #expect(HomeMosaic.reclaimableBytes(
            tiles: [tile(.userCaches, quarter), tile(.userLogs, quarter)], excluding: [.userCaches], trashBytes: 5)
            == quarter + 5)
    }

    @Test func onlyReadablePlacesAreScanned() throws {
        let rig = try ModelRig()
        let catalog = JunkCatalog.standard(rig.environment, options: rig.options)
        let places = catalog.map { Place(id: $0.id, access: $0.id == .userLogs ? .readable : .locked) }
        #expect(HomeMosaic.scannable(catalog, places: places).map(\.id) == [.userLogs])
        #expect(HomeMosaic.scannable(catalog, places: nil).isEmpty)
        let unreadable = catalog.map { Place(id: $0.id, access: $0.id == .userLogs ? .unreadable : .readable) }
        #expect(!HomeMosaic.scannable(catalog, places: unreadable).map(\.id).contains(.userLogs))
    }

    @Test func accessibilitySummaryReadsAsOneSentence() {
        #expect(HomeMosaic.accessibilitySummary(reclaimable: 15 * UInt64(gb), categories: 6, locked: 5)
            == "Reclaimable: 15 GB in 6 categories; 5 places locked")
        #expect(HomeMosaic.accessibilitySummary(reclaimable: UInt64(gb), categories: 1, locked: 0)
            == "Reclaimable: 1 GB in 1 category")
    }
}
