import SwiftUI

/// The pixel icons the approved shell uses but `DustlingTheme.PixelIcon` doesn't define yet.
/// Bitmaps copied from the `PICON` additions in the approved mockups (`screens.html`, "Mosaic" round).
enum ShellPixelIcon: String, CaseIterable {
    case home, broom, clock, folder

    var rows: [String] {
        switch self {
        case .home:  return ["...XX...", "..XXXX..", ".XXXXXX.", "XXXXXXXX", ".X....X.", ".X.XX.X.", ".X.XX.X.", ".XXXXXX."]
        case .broom: return ["......XX", ".....XX.", "....XX..", "...XX...", ".XXXX...", "XXXXXX..", "XXXXXX..", ".X.X.X.."]
        case .clock: return ["..XXXX..", ".X....X.", "X...X..X", "X...X..X", "X...XX.X", "X......X", ".X....X.", "..XXXX.."]
        case .folder: return ["........", "XXX.....", "X..XXXXX", "X......X", "X......X", "X......X", "XXXXXXXX", "........"]
        }
    }
}

/// An 8 x 8 pixel icon drawn with `Canvas` at an integer scale: 16 pt (2x) by default, or 8 pt for chips.
/// It never scales by a non-integer factor (DESIGN-mosaic §6).
struct PixelIconView: View {
    enum Size {
        /// 16 pt, 2 pt per pixel. The default everywhere.
        case regular
        /// 8 pt, 1 pt per pixel. Chips only.
        case small

        var pixel: CGFloat { self == .regular ? 2 : 1 }
    }

    /// How the icon is colored.
    enum Tint {
        /// Always this color.
        case color(Color)
        /// The surrounding foreground style, like the text next to it. Use it inside button labels:
        /// the icon then follows the button's state the way its title does (white on an active
        /// primary button, the label color when the window is inactive, dimmed when disabled).
        case foreground
    }

    private let rows: [[Character]]
    private let tint: Tint
    private let size: Size

    init(_ icon: PixelIcon, color: Color = DustlingTheme.Palette.ink, size: Size = .regular) {
        self.init(rows: icon.rows, tint: .color(color), size: size)
    }

    init(_ icon: ShellPixelIcon, color: Color = DustlingTheme.Palette.ink, size: Size = .regular) {
        self.init(rows: icon.rows, tint: .color(color), size: size)
    }

    init(_ icon: PixelIcon, tint: Tint, size: Size = .regular) {
        self.init(rows: icon.rows, tint: tint, size: size)
    }

    init(_ icon: ShellPixelIcon, tint: Tint, size: Size = .regular) {
        self.init(rows: icon.rows, tint: tint, size: size)
    }

    private init(rows: [String], tint: Tint, size: Size) {
        self.rows = rows.map { Array($0) }
        self.tint = tint
        self.size = size
    }

    var body: some View {
        switch tint {
        case .color(let color):
            PixelArt(rows: rows, pixel: size.pixel) { $0 == "X" ? color : nil }
        case .foreground:
            // The bitmap masks a fill in the current foreground style, so it renders exactly like
            // the label text beside it in every button state.
            let art = PixelArt(rows: rows, pixel: size.pixel) { $0 == "X" ? .black : nil }
            Rectangle()
                .fill(.foreground)
                .frame(width: CGFloat(rows.first?.count ?? 0) * size.pixel, height: CGFloat(rows.count) * size.pixel)
                .mask(art)
                .accessibilityHidden(true)
        }
    }
}
