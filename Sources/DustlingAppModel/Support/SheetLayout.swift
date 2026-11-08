import Foundation

/// How a confirmation sheet fits the window. A sheet sizes itself to its content and is never clipped
/// to the window, so a sheet with a long list (or several notes) could push its buttons off screen.
/// Each sheet pins its header and its button row and puts everything between them in one scroll view
/// no taller than `middleCap`, so the whole sheet fits even the smallest window.
public struct SheetLayout: Equatable, Sendable {
    /// The main window's minimum height (`RootView`).
    public static let minWindowHeight: Double = 560
    /// Room above an attached sheet (the title bar) and a margin below it.
    public static let windowChrome: Double = 52 + 16
    /// The height a sheet may take in the smallest window.
    public static var available: Double { minWindowHeight - windowChrome }
    /// Buttons at the regular control size, with room for a focus ring.
    public static let buttonRowHeight: Double = 32

    /// Padding above and below the sheet's content.
    public let verticalPadding: Double
    /// The tallest the pinned header gets (its text is limited to a set number of lines).
    public let headerHeight: Double
    /// The gap between header, middle and buttons.
    public let spacing: Double

    public init(verticalPadding: Double, headerHeight: Double, spacing: Double) {
        self.verticalPadding = verticalPadding
        self.headerHeight = headerHeight
        self.spacing = spacing
    }

    /// Everything but the middle.
    public var pinnedHeight: Double {
        2 * verticalPadding + headerHeight + 2 * spacing + Self.buttonRowHeight
    }

    /// The tallest the scrolling middle may be.
    public var middleCap: Double { Self.available - pinnedHeight }

    /// The whole sheet at its tallest.
    public var maxHeight: Double { pinnedHeight + middleCap }

    /// "Move 3 apps to the Trash?": Mote, a one-line title and a two-line message.
    public static let uninstallConfirm = SheetLayout(verticalPadding: 20, headerHeight: 76, spacing: 12)
    /// "Close 3 apps to include their files?": a title of up to two lines.
    public static let closeApps = SheetLayout(verticalPadding: 20, headerHeight: 42, spacing: 14)
    /// "Empty the Trash?": icon and a one-line title.
    public static let emptyTrash = SheetLayout(verticalPadding: 20, headerHeight: 28, spacing: 14)

    public static let all: [SheetLayout] = [uninstallConfirm, closeApps, emptyTrash]
}
