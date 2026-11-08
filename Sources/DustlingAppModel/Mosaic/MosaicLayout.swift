import DustlingCore

public enum CellKind: Hashable, Sendable {
    case free, category(JunkCategoryID), inTrash, locked, other
}

/// Maps a category to its colour slot in the chart palette (DESIGN-mosaic section 2). nil = neutral.
public enum CategorySeries {
    public static func slot(for id: JunkCategoryID) -> Int? {
        switch id {
        case .xcodeJunk: 1
        case .systemCachesAndLogs: 2
        case .userCaches: 3
        case .packageManagerCaches: 4
        case .userLogs: 5
        case .browserCaches: 6
        case .oldInstallers, .iosBackups, .xcodeArchives, .largeOldDownloads, .mailDownloads: 7
        case .trash: nil
        }
    }
}

/// The storage mosaic: a grid of cells filled column by column, `rows` cells tall.
///
/// One cell is 0.25 GiB (268,435,456 bytes; Ruling R31). That is a binary unit while `Bytes.format` is
/// decimal, on purpose: a cell is a visual unit, not a displayed size.
public struct MosaicLayout: Equatable, Sendable {
    public var cells: [CellKind]
    public static let rowCount = 4
    public var rows: Int = MosaicLayout.rowCount
    public var columns: Int

    /// Order: free, categories (largest first), inTrash, locked (one cell per place), other.
    /// Every part with bytes > 0 gets at least one cell (ceiling); `other` absorbs the remaining
    /// difference down to zero, never negative.
    public static func make(
        totalBytes: Int64, availableBytes: Int64, categories: [(JunkCategoryID, UInt64)],
        inTrashBytes: UInt64, lockedPlaces: Int, cellBytes: UInt64 = 268_435_456
    ) -> MosaicLayout {
        let size = max(cellBytes, 1)
        func ceilCells(_ bytes: UInt64) -> Int {
            let (q, r) = bytes.quotientAndRemainder(dividingBy: size)
            return Int(clamping: q) + (r > 0 ? 1 : 0)
        }

        let totalCells = ceilCells(UInt64(max(0, totalBytes)))
        var cells = Array(repeating: CellKind.free, count: ceilCells(UInt64(max(0, availableBytes))))

        // The Trash is shown only through `inTrashBytes` (hatched); a .trash entry would double count.
        let ordered = categories.enumerated()
            .filter { $0.element.1 > 0 && $0.element.0 != .trash }
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
        for (_, entry) in ordered {
            cells += Array(repeating: .category(entry.0), count: ceilCells(entry.1))
        }
        cells += Array(repeating: .inTrash, count: ceilCells(inTrashBytes))
        cells += Array(repeating: .locked, count: max(0, lockedPlaces))
        if totalCells > cells.count {
            cells += Array(repeating: .other, count: totalCells - cells.count)
        }
        let rows = rowCount
        return MosaicLayout(cells: cells, rows: rows, columns: (cells.count + rows - 1) / rows)
    }
}
