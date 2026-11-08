// DustlingTheme.swift
// Design tokens for the Mosaic theme. Source of truth: DESIGN-mosaic.md.
// macOS 14+, SwiftUI. Drop into the app target; nothing here touches the file system except font registration.

import SwiftUI
import AppKit
import CoreText

public enum DustlingTheme {

    // MARK: - Colour

    public enum Palette {
        public static let ground           = dynamic(light: 0xFFFFFF, dark: 0x121317)
        public static let sidebar          = dynamic(light: 0xF4F5F7, dark: 0x1A1B21)
        public static let sidebarInk       = dynamic(light: 0x15171C, dark: 0xF1F2F5)
        public static let sidebarMuted     = dynamic(light: 0x5B606B, dark: 0x9A9EA8)
        public static let sidebarSelection = dynamic(light: 0xE6E9EF, dark: 0x2B2D35)
        public static let sidebarIcon      = dynamic(light: 0x3D3BF3, dark: 0x9D9BFF)
        public static let ink              = dynamic(light: 0x15171C, dark: 0xF1F2F5)
        public static let ink2             = dynamic(light: 0x363A44, dark: 0xCBCED6)
        public static let muted            = dynamic(light: 0x5D626D, dark: 0x989CA6)
        public static let line             = dynamic(light: 0xE8EAEE, dark: 0x2A2C33)
        public static let panel            = dynamic(light: 0xF6F7F9, dark: 0x1A1B21)
        public static let rowSelection     = dynamic(light: 0xEEEDFF, dark: 0x22224A)
        public static let accent           = dynamic(light: 0x3D3BF3, dark: 0x9D9BFF)
        public static let accentFill       = dynamic(light: 0x3D3BF3, dark: 0x4C4AF0)
        public static let onAccent         = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)
        public static let warning          = dynamic(light: 0xA84A00, dark: 0xFFA24A)
        public static let success          = dynamic(light: 0x0F7D52, dark: 0x3DD69A)
        public static let danger           = dynamic(light: 0xD3263B, dark: 0xFF5C70)
        public static let neutralCell      = dynamic(light: 0xDADDE3, dark: 0x2E3038)
    }

    /// Category series for mosaic cells, row bars and legend keys. Never for chrome or text backgrounds.
    public enum Series: Int, CaseIterable {
        case c1, c2, c3, c4, c5, c6, c7

        public var color: Color {
            switch self {
            case .c1: return dynamic(light: 0x3D3BF3, dark: 0x8E8CFF)
            case .c2: return dynamic(light: 0xFF8A00, dark: 0xFFA040)
            case .c3: return dynamic(light: 0x00B37E, dark: 0x2FD49A)
            case .c4: return dynamic(light: 0xE5409A, dark: 0xFF6BB5)
            case .c5: return dynamic(light: 0x00A3E0, dark: 0x3CC4F5)
            case .c6: return dynamic(light: 0x8B5CF6, dark: 0xA98BFF)
            case .c7: return dynamic(light: 0xF5C400, dark: 0xFFD84A)
            }
        }
    }

    /// Mote and the app icon keep the Dusk palette in both appearances.
    public enum Mascot {
        public static let body   = Color(hex: 0xD9D2F0)
        public static let shade  = Color(hex: 0xA59CCB)
        public static let ink    = Color(hex: 0x1E1B33)
        public static let shine  = Color(hex: 0xFFFFFF)
        public static let blush  = Color(hex: 0xF4A7C0)
        public static let sweat  = Color(hex: 0x7CC4FF)
        public static let tileTop = Color(hex: 0x3B3566), tileBottom = Color(hex: 0x262142)
        public static let tileTopDark = Color(hex: 0x25232F), tileBottomDark = Color(hex: 0x16151C)
    }

    // MARK: - Type

    public enum Typography {
        public static let pixelFamily = "Geist Pixel"
        public static let sansFamily  = "Geist"
        public static let monoFamily  = "Geist Mono"
        public static let lockupFamily = "Pixelify Sans"

        public static let body        = Font.custom(sansFamily, size: 13, relativeTo: .body)
        public static let rowTitle    = Font.custom(sansFamily, size: 13, relativeTo: .body).weight(.semibold)
        public static let caption     = Font.custom(sansFamily, size: 11.5, relativeTo: .caption)
        public static let size        = Font.custom(sansFamily, size: 13, relativeTo: .body).weight(.semibold).monospacedDigit()
        public static let path        = Font.custom(monoFamily, size: 11.5, relativeTo: .caption)
        public static let windowTitle = Font.custom(pixelFamily, size: 16, relativeTo: .title3)
        public static let figure      = Font.custom(pixelFamily, size: 26, relativeTo: .title).monospacedDigit()
        public static let figureLarge = Font.custom(pixelFamily, size: 36, relativeTo: .largeTitle).monospacedDigit()
        public static let lockup      = Font.custom(lockupFamily, size: 16, relativeTo: .headline).weight(.semibold)
    }

    /// Registers bundled fonts (Geist, Geist Mono, Geist Pixel, Pixelify Sans; all SIL OFL 1.1).
    /// Call once at launch. Put the .ttf files in a "Fonts" folder of the given bundle.
    public static func registerFonts(in bundle: Bundle = .main, subdirectory: String = "Fonts") {
        let urls = (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: subdirectory) ?? [])
                 + (bundle.urls(forResourcesWithExtension: "otf", subdirectory: subdirectory) ?? [])
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered is fine; anything else should be logged, never silently ignored.
                if let err = error?.takeRetainedValue() { NSLog("Dustling font registration: \(url.lastPathComponent): \(err)") }
            }
        }
    }

    // MARK: - Metrics

    public enum Metrics {
        public static let sidebarWidth: CGFloat = 236
        public static let contentMinWidth: CGFloat = 860
        public static let defaultWindow = CGSize(width: 1180, height: 740)
        public static let toolbarHeight: CGFloat = 56
        public static let actionBarHeight: CGFloat = 60
        public static let rowMinHeight: CGFloat = 48
        public static let rowPadding = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        public static let columnGap: CGFloat = 12
        public static let gutter: CGFloat = 20
        public static let panelRadius: CGFloat = 10
        public static let controlRadius: CGFloat = 6
        public static let chipHeight: CGFloat = 20
        public static let iconSize: CGFloat = 16      // pixel icons: always exactly 2x of 8 px
        public static let iconTile: CGFloat = 30
        public static let barHeight: CGFloat = 6      // segmented row bar: 4 on, 2 off
        public static let mosaicGB: Double = 0.25     // one cell
        public static let mosaicRows = 4
        public static let mosaicGap: CGFloat = 2
    }

    // MARK: - Motion

    public enum Motion {
        public static let hover = Animation.easeOut(duration: 0.15)
        public static let toggle = Animation.easeOut(duration: 0.2)
        public static let checkPop = Animation.spring(response: 0.32, dampingFraction: 0.6)
        public static let meter = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6)
        public static let countUpDuration: Double = 0.9
        public static let skeletonPulse: Double = 1.3
        public static let skeletonStagger: Double = 0.12
        public static let nibbleStagger: Double = 0.007   // per cell
        public static let nibbleStaggerCap: Double = 0.42
        public static let chompFrame: Double = 0.17
        public static let sniffCrossing: Double = 3.2
        public static let sleepyBreath: Double = 3.4

        /// Use instead of withAnimation in views: returns nil under Reduce Motion so values change instantly.
        public static func animation(_ a: Animation, reduceMotion: Bool) -> Animation? { reduceMotion ? nil : a }
    }

    // MARK: - Helpers

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

// MARK: - Pixel art (icons and Mote)

/// 8x8 pixel icons. "X" is a lit pixel. Draw at exactly 16 pt (2x) or 8 pt.
public enum PixelIcon: String, CaseIterable {
    case disk, apps, power, trash, hammer, gear, layers, box, doc, mail, phone, check, warn, lock, shield, search, refresh, arrow, undo, sort, info

    public var rows: [String] {
        switch self {
        case .disk:    return ["XXXXXXXX", "X......X", "X......X", "XXXXXXXX", "X......X", "X....X.X", "X......X", "XXXXXXXX"]
        case .apps:    return ["XXX.XXX.", "X.X.X.X.", "XXX.XXX.", "........", "XXX.....", "X.X.XXXX", "XXX.....", "........"]
        case .power:   return ["...XX...", ".X.XX.X.", "X..XX..X", "X......X", "X......X", "X......X", ".X....X.", "..XXXX.."]
        case .trash:   return ["..XXXX..", "XXXXXXXX", ".X....X.", ".X.XX.X.", ".X.XX.X.", ".X.XX.X.", ".X....X.", "..XXXX.."]
        case .hammer:  return ["XXXX....", "XXXXX...", ".XXXXX..", "...XXX..", "....XXX.", ".....XXX", "......XX", "........"]
        case .gear:    return ["...XX...", ".X.XX.X.", "..XXXX..", "XXX..XXX", "XXX..XXX", "..XXXX..", ".X.XX.X.", "...XX..."]
        case .layers:  return ["...XX...", ".XX..XX.", "X......X", ".XX..XX.", "X..XX..X", ".XX..XX.", "...XX...", "........"]
        case .box:     return [".XXXXXX.", "X..XX..X", "XXXXXXXX", "X......X", "X..XX..X", "X......X", "XXXXXXXX", "........"]
        case .doc:     return ["XXXXX...", "X...XX..", "X....XX.", "X.XXX.X.", "X.....X.", "X.XXX.X.", "X.....X.", "XXXXXXX."]
        case .mail:    return ["XXXXXXXX", "XX....XX", "X.X..X.X", "X..XX..X", "X......X", "X......X", "XXXXXXXX", "........"]
        case .phone:   return [".XXXXXX.", ".X....X.", ".X....X.", ".X....X.", ".X....X.", ".X....X.", ".X.XX.X.", ".XXXXXX."]
        case .check:   return ["........", ".......X", "......XX", "X....XX.", "XX..XX..", ".XXXX...", "..XX....", "........"]
        case .warn:    return ["...XX...", "..XXXX..", "..X..X..", ".X.XX.X.", ".X.XX.X.", "X......X", "X..XX..X", "XXXXXXXX"]
        case .lock:    return ["..XXXX..", ".X....X.", ".X....X.", "XXXXXXXX", "X..XX..X", "X..XX..X", "X......X", "XXXXXXXX"]
        case .shield:  return ["XXXXXXXX", "X......X", "X....X.X", "X...X..X", "XX.X..XX", ".XX..XX.", "..XXXX..", "...XX..."]
        case .search:  return [".XXXX...", "X....X..", "X....X..", "X....X..", ".XXXX...", "....XX..", ".....XX.", "......XX"]
        case .refresh: return ["..XXXX..", ".X....XX", "X....XXX", "X.......", ".......X", "XXX....X", "XX....X.", "..XXXX.."]
        case .arrow:   return ["....X...", "....XX..", "XXXXXXX.", "XXXXXXXX", "XXXXXXX.", "....XX..", "....X...", "........"]
        case .undo:    return ["..X.....", ".XX.....", "XXXXXX..", ".XX...X.", "..X....X", ".......X", "......X.", "..XXXX.."]
        case .sort:    return ["XXXXXXXX", "........", "XXXXXX..", "........", "XXXX....", "........", "XX......", "........"]
        case .info:    return ["..XXXX..", ".X....X.", "X..XX..X", "X......X", "X..XX..X", "X..XX..X", ".X....X.", "..XXXX.."]
        }
    }
}

/// Mote, 16 x 15. a body, b shade, c eye, e shine, h blush, k mouth, w sweat.
public enum Mote {
    public enum Face { case idle, chompOpen, happy, worried, sleepy }

    public static let base: [String] = [
        "........aa......", ".......a........", ".....aaaaaa.....", "...aaaaaaaaaa...", "..aaeeaaaaaaaa..",
        "..aeaaaaaaaaaa..", ".aaaaaaaaaaaaaa.", ".aaaacaaaacaaaa.", ".aaaacaaaacaaab.", "aaaahaaaaaahaab.",
        ".aaaaaaaaaaaabb.", "..aaaaaaaaaabb..", "..aaaaaaaaabbb..", "...bbaaaaabbb...", ".....bbbbbb....."
    ]

    public static func grid(_ face: Face) -> [[Character]] {
        var g = base.map { Array($0) }
        func set(_ x: Int, _ y: Int, _ ch: Character) { if y < g.count, x < g[y].count { g[y][x] = ch } }
        let eyes = [(5, 7), (5, 8), (10, 7), (10, 8)]
        switch face {
        case .idle: break
        case .chompOpen: [(7, 10), (8, 10), (7, 11), (8, 11)].forEach { set($0.0, $0.1, "k") }
        case .happy:
            eyes.forEach { set($0.0, $0.1, "a") }
            [(4, 8), (5, 7), (6, 8), (9, 8), (10, 7), (11, 8)].forEach { set($0.0, $0.1, "c") }
            [(6, 10), (9, 10), (7, 11), (8, 11)].forEach { set($0.0, $0.1, "k") }
        case .worried:
            [(4, 6), (5, 5), (11, 6), (10, 5)].forEach { set($0.0, $0.1, "c") }
            [(7, 11), (8, 11)].forEach { set($0.0, $0.1, "k") }
            [(13, 7), (13, 8)].forEach { set($0.0, $0.1, "w") }
        case .sleepy:
            eyes.forEach { set($0.0, $0.1, "a") }
            [(4, 8), (5, 8), (10, 8), (11, 8)].forEach { set($0.0, $0.1, "c") }
        }
        return g
    }

    static func color(for ch: Character) -> Color? {
        switch ch {
        case "a": return DustlingTheme.Mascot.body
        case "b": return DustlingTheme.Mascot.shade
        case "c", "k": return DustlingTheme.Mascot.ink
        case "e": return DustlingTheme.Mascot.shine
        case "h": return DustlingTheme.Mascot.blush
        case "w": return DustlingTheme.Mascot.sweat
        default: return nil
        }
    }
}

/// Draws a pixel grid crisply at an integer scale.
public struct PixelArt: View {
    let rows: [[Character]]
    let pixel: CGFloat
    let colorFor: (Character) -> Color?

    public init(rows: [[Character]], pixel: CGFloat, colorFor: @escaping (Character) -> Color?) {
        self.rows = rows; self.pixel = pixel.rounded(); self.colorFor = colorFor
    }

    public var body: some View {
        let w = CGFloat(rows.first?.count ?? 0) * pixel, h = CGFloat(rows.count) * pixel
        Canvas { ctx, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = colorFor(ch) else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)), with: .color(c))
                }
            }
        }
        .frame(width: w, height: h)
        .accessibilityHidden(true)
    }
}

public extension PixelArt {
    /// A 16 pt pixel icon tinted with `color`.
    static func icon(_ icon: PixelIcon, color: Color = DustlingTheme.Palette.ink, pixel: CGFloat = 2) -> PixelArt {
        PixelArt(rows: icon.rows.map { Array($0) }, pixel: pixel) { $0 == "X" ? color : nil }
    }
    /// Mote at an integer scale: 2 (32 pt), 3 (48 pt) or 6 (96 pt).
    static func mote(_ face: Mote.Face = .idle, pixel: CGFloat = 3) -> PixelArt {
        PixelArt(rows: Mote.grid(face), pixel: pixel, colorFor: Mote.color(for:))
    }
}

// MARK: - Colour helpers

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}
