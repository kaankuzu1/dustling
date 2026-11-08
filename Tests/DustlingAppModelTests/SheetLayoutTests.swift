import Testing
@testable import DustlingAppModel

/// Every confirmation sheet keeps its buttons in the smallest window: the pinned header, buttons and
/// padding plus the scrolling middle at its tallest add up to no more than the window has room for.
struct SheetLayoutTests {
    @Test(arguments: SheetLayout.all)
    func sheetFitsTheSmallestWindow(_ layout: SheetLayout) {
        let total = 2 * layout.verticalPadding + layout.headerHeight + 2 * layout.spacing
            + SheetLayout.buttonRowHeight + layout.middleCap
        #expect(total == layout.maxHeight)
        #expect(total <= SheetLayout.minWindowHeight - SheetLayout.windowChrome)
        #expect(SheetLayout.windowChrome >= 52)
    }

    /// The middle still has room for a useful amount: at least five 44 pt rows.
    @Test(arguments: SheetLayout.all)
    func middleShowsSeveralRows(_ layout: SheetLayout) {
        #expect(layout.middleCap >= 5 * 44)
    }

    @Test func pinnedPartsAddUp() {
        let layout = SheetLayout(verticalPadding: 20, headerHeight: 76, spacing: 12)
        #expect(layout.pinnedHeight == 40 + 76 + 24 + 32)
        #expect(layout.middleCap == SheetLayout.available - layout.pinnedHeight)
    }
}
