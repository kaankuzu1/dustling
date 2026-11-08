import SwiftUI

/// The pixel icons the approved shell uses but `DustlingTheme.PixelIcon` doesn't define yet.
/// Bitmaps copied from the `PICON` additions in the approved mockups (`screens.html`, "Mosaic" round).
enum ShellPixelIcon: String, CaseIterable {
    case home, broom, clock

    var rows: [String] {
        switch self {
        case .home:  return ["...XX...", "..XXXX..", ".XXXXXX.", "XXXXXXXX", ".X....X.", ".X.XX.X.", ".X.XX.X.", ".XXXXXX."]
        case .broom: return ["......XX", ".....XX.", "....XX..", "...XX...", ".XXXX...", "XXXXXX..", "XXXXXX..", ".X.X.X.."]
        case .clock: return ["..XXXX..", ".X....X.", "X...X..X", "X...X..X", "X...XX.X", "X......X", ".X....X.", "..XXXX.."]
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

    private let rows: [[Character]]
    private let color: Color
    private let size: Size

    init(_ icon: PixelIcon, color: Color = DustlingTheme.Palette.ink, size: Size = .regular) {
        self.init(rows: icon.rows, color: color, size: size)
    }

    init(_ icon: ShellPixelIcon, color: Color = DustlingTheme.Palette.ink, size: Size = .regular) {
        self.init(rows: icon.rows, color: color, size: size)
    }

    private init(rows: [String], color: Color, size: Size) {
        self.rows = rows.map { Array($0) }
        self.color = color
        self.size = size
    }

    var body: some View {
        let color = self.color
        PixelArt(rows: rows, pixel: size.pixel) { $0 == "X" ? color : nil }
    }
}
