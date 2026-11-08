import Testing
@testable import DustlingAppModel

/// A sheet sizes itself to its content and isn't clipped to the window, so a list in a sheet is held
/// to a few rows and scrolls past that, with a line saying how many more there are.
struct SheetListTests {
    @Test func shortListsTakeTheirOwnHeightAndDontScroll() {
        let list = SheetList(rows: 3, rowHeight: 40, spacing: 4, maxVisible: 6)
        #expect(list.height == 3 * 40 + 2 * 4)
        #expect(!list.scrolls)
        #expect(list.hidden == 0)
        #expect(list.moreLine(one: "app", many: "apps") == nil)
    }

    @Test func aFullListStillDoesntScroll() {
        let list = SheetList(rows: 6, rowHeight: 40, spacing: 4, maxVisible: 6)
        #expect(!list.scrolls && list.hidden == 0)
        #expect(list.height == 6 * 40 + 5 * 4)
    }

    @Test func longListsStopAtTheCapAndScroll() {
        let capped = SheetList(rows: 6, rowHeight: 40, spacing: 4, maxVisible: 6)
        for rows in [7, 21, 50, 500] {
            let list = SheetList(rows: rows, rowHeight: 40, spacing: 4, maxVisible: 6)
            #expect(list.scrolls)
            #expect(list.height == capped.height)
            #expect(list.hidden == rows - 6)
        }
    }

    @Test func moreLineIsSingularOrPlural() {
        #expect(SheetList(rows: 7, rowHeight: 40, spacing: 4, maxVisible: 6).moreLine(one: "app", many: "apps")
            == "and 1 more app")
        #expect(SheetList(rows: 21, rowHeight: 40, spacing: 4, maxVisible: 6).moreLine(one: "app", many: "apps")
            == "and 15 more apps")
    }

    @Test func emptyAndNonsenseInputs() {
        #expect(SheetList(rows: 0, rowHeight: 40, spacing: 4, maxVisible: 6).height == 0)
        #expect(SheetList(rows: -3, rowHeight: 40, spacing: 4, maxVisible: 6).height == 0)
        let one = SheetList(rows: 5, rowHeight: 48, spacing: 0, maxVisible: 0)
        #expect(one.height == 48 && one.scrolls && one.hidden == 4)
    }

    /// The sheets' own lists, at the sizes that keep a sheet inside the smallest window (560 pt tall).
    @Test func sheetListsStayShortWithFiftyRows() {
        #expect(UninstallerScreen.confirmList(apps: 50).height <= 280)
        #expect(UninstallerScreen.confirmList(apps: 50).scrolls)
        #expect(UninstallerScreen.confirmList(apps: 3).height == 3 * 40 + 2 * 4)
        #expect(CloseApps.list(holders: 50).height <= 260)
        #expect(CloseApps.list(holders: 50).scrolls)
        #expect(!CloseApps.list(holders: 2).scrolls)
    }
}
