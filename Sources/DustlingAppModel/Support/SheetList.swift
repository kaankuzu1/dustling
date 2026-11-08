import Foundation

/// The height of a list inside a sheet. A sheet sizes itself to its content and is never clipped to
/// the window, so a list with one row per item (apps to remove, apps to close) would push the
/// buttons off the window once it is long. The list shows at most `maxVisible` rows and scrolls past
/// that; `moreLine` says how many rows are below the first ones.
public struct SheetList: Equatable, Sendable {
    /// The list's height: the visible rows and the gaps between them.
    public let height: Double
    /// More rows than fit: the list scrolls.
    public let scrolls: Bool
    /// Rows beyond the first `maxVisible`.
    public let hidden: Int

    public init(rows: Int, rowHeight: Double, spacing: Double, maxVisible: Int) {
        let rows = max(rows, 0)
        let shown = min(rows, max(maxVisible, 1))
        height = shown == 0 ? 0 : Double(shown) * rowHeight + Double(shown - 1) * spacing
        scrolls = rows > shown
        hidden = rows - shown
    }

    /// "and 15 more apps", or nil when every row is in view.
    public func moreLine(one: String, many: String) -> String? {
        guard hidden > 0 else { return nil }
        return "and \(hidden) more \(hidden == 1 ? one : many)"
    }
}
