import Testing
import DustlingCore
@testable import DustlingAppModel

struct MosaicLayoutTests {
    let cell: Int64 = 268_435_456

    func make(
        total: Int64 = 100 * 268_435_456, available: Int64 = 40 * 268_435_456,
        categories: [(JunkCategoryID, UInt64)] = [], inTrash: UInt64 = 0, locked: Int = 0
    ) -> MosaicLayout {
        MosaicLayout.make(
            totalBytes: total, availableBytes: available, categories: categories,
            inTrashBytes: inTrash, lockedPlaces: locked)
    }

    @Test func freeCellsComeFirstThenLargestCategory() {
        let layout = make(categories: [(.userLogs, UInt64(cell) * 2), (.xcodeJunk, UInt64(cell) * 5)])
        #expect(layout.cells.prefix(40).allSatisfy { $0 == .free })
        #expect(Array(layout.cells[40..<45]) == Array(repeating: .category(.xcodeJunk), count: 5))
        #expect(Array(layout.cells[45..<47]) == Array(repeating: .category(.userLogs), count: 2))
        #expect(layout.cells.count == 100)
        #expect(layout.cells.last == .other)
    }

    @Test func tinyCategoryGetsOneCell() {
        let layout = make(categories: [(.browserCaches, 10)])
        #expect(layout.cells.filter { $0 == .category(.browserCaches) }.count == 1)
    }

    @Test func zeroByteCategoryGetsNoCell() {
        let layout = make(categories: [(.browserCaches, 0)])
        #expect(!layout.cells.contains(.category(.browserCaches)))
    }

    @Test func inTrashCellsAreHatchedUntilEmptied() {
        let without = make()
        let with = make(inTrash: UInt64(cell) * 3)
        #expect(with.cells.filter { $0 == .inTrash }.count == 3)
        #expect(without.cells.filter { $0 == .inTrash }.isEmpty)
        #expect(with.cells.filter { $0 == .free }.count == without.cells.filter { $0 == .free }.count)
    }

    @Test func lockedPlacesRenderAsLockedNotZero() {
        let layout = make(locked: 2)
        #expect(layout.cells.filter { $0 == .locked }.count == 2)
    }

    @Test func columnsAreCeilOfCellsOverFour() {
        #expect(make().columns == 25)
        let odd = make(total: 10 * cell + 1, available: 0)
        #expect(odd.cells.count == 11)
        #expect(odd.columns == 3)
        #expect(odd.rows == 4)
    }

    @Test func otherAbsorbsRemainderNeverNegative() {
        let over = make(total: 10 * cell, available: 8 * cell, categories: [(.userCaches, UInt64(cell) * 5)])
        #expect(!over.cells.contains(.other))
        #expect(over.cells.count == 13)
    }

    @Test func categorySlotMapping() {
        #expect(CategorySeries.slot(for: .xcodeJunk) == 1)
        #expect(CategorySeries.slot(for: .systemCachesAndLogs) == 2)
        #expect(CategorySeries.slot(for: .userCaches) == 3)
        #expect(CategorySeries.slot(for: .packageManagerCaches) == 4)
        #expect(CategorySeries.slot(for: .userLogs) == 5)
        #expect(CategorySeries.slot(for: .browserCaches) == 6)
        for id: JunkCategoryID in [.oldInstallers, .iosBackups, .xcodeArchives, .largeOldDownloads, .mailDownloads] {
            #expect(CategorySeries.slot(for: id) == 7)
        }
        #expect(CategorySeries.slot(for: .trash) == nil)
    }
}
