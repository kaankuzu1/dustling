import DustlingAppModel
import SwiftUI

// Loading skeletons (DESIGN-mosaic §8): `panel`-coloured blocks in the shape of the rows that will
// appear, pulsing in opacity only (1.3 s), staggered 0.12 s per row, still under Reduce Motion.
//
// A skeleton is never drawn by hand. Each screen draws its real row view with placeholder data
// (`StartupRow.placeholder(_:)` and friends) inside `.skeleton(true, index:)`. In that mode the
// row's texts (`.skeletonText()`) and controls and icons (`.skeletonBlock()`) keep their exact size
// and place but show as blocks. The skeleton therefore has the row's container, padding, column
// widths and height by construction, and the loaded row replaces it without moving anything.

extension EnvironmentValues {
    /// Non-nil while views draw as their loading skeleton: the row's place, for the pulse's stagger.
    @Entry var skeletonIndex: Int?
    /// The skeleton sits on a `panel` surface (hero, tool cards), where `panel` blocks would vanish.
    @Entry var skeletonOnPanel = false
}

extension View {
    /// Draws this subtree as its loading skeleton while `active`; `index` staggers the pulse.
    func skeleton(_ active: Bool, index: Int = 0) -> some View {
        transformEnvironment(\.skeletonIndex) { if active { $0 = index } }
            .allowsHitTesting(!active)
            .accessibilityHidden(active)
    }

    /// Marks a `panel`-filled container, so skeleton blocks inside it stay visible.
    func skeletonSurfaceIsPanel() -> some View {
        environment(\.skeletonOnPanel, true)
    }

    /// In a skeleton: one block the exact size of this view (a control, an icon, a meter).
    func skeletonBlock(cornerRadius: CGFloat = SkeletonMetrics.textRadius) -> some View {
        modifier(SkeletonBlockModifier(cornerRadius: cornerRadius))
    }

    /// In a skeleton: a line of text as a block as wide as the text and as tall as its glyphs,
    /// centred on the line, so the line keeps its exact height and baseline.
    func skeletonText() -> some View {
        modifier(SkeletonTextModifier())
    }
}

/// The skeleton's few metrics, in one place.
enum SkeletonMetrics {
    /// Corner radius of text lines and small controls (the mockups' `.sk`: 4 px).
    static let textRadius: CGFloat = 4
    /// A text block covers this share of its line's height: the glyphs, not the leading.
    static let textHeightRatio: CGFloat = 0.62
    /// Fewest and most placeholder rows a list shows.
    static let minRows = 3
    static let maxRows = 24

    /// How many placeholder rows, `rowHeight` tall with `spacing` between them, fit in `height`
    /// (the list's visible height less its padding), so the skeleton fills the list without scrolling.
    static func rowCount(height: CGFloat, rowHeight: CGFloat, spacing: CGFloat = 0) -> Int {
        guard height > 0, rowHeight > 0 else { return minRows }
        let rows = Int(((height + spacing) / (rowHeight + spacing)).rounded(.down))
        return min(maxRows, max(minRows, rows))
    }
}

private struct SkeletonBlockModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.skeletonIndex) private var index

    func body(content: Content) -> some View {
        if let index {
            content
                .hidden()
                .overlay { SkeletonBlock(cornerRadius: cornerRadius, index: index) }
        } else {
            content
        }
    }
}

private struct SkeletonTextModifier: ViewModifier {
    @Environment(\.skeletonIndex) private var index

    func body(content: Content) -> some View {
        if let index {
            content
                .hidden()
                .overlay {
                    GeometryReader { proxy in
                        SkeletonBlock(
                            height: (proxy.size.height * SkeletonMetrics.textHeightRatio).rounded(),
                            cornerRadius: SkeletonMetrics.textRadius, index: index)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
        } else {
            content
        }
    }
}

/// One placeholder block. It fills the space it is given unless `width` or `height` is set. It pulses
/// in opacity only; under Reduce Motion or while the window isn't key it stays still.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat?
    var cornerRadius: CGFloat = SkeletonMetrics.textRadius
    /// The row's place, used for the stagger.
    var index: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.skeletonOnPanel) private var onPanel

    var body: some View {
        Group {
            if !reduceMotion && controlActiveState == .key {
                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
                    block.opacity(Self.opacity(at: context.date, index: index))
                }
            } else {
                block
            }
        }
        .accessibilityHidden(true)
    }

    private var block: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            // On a `panel` surface a `panel` block would vanish: one step darker, `line`.
            .fill(onPanel ? DustlingTheme.Palette.line : DustlingTheme.Palette.panel)
            .frame(width: width, height: height)
    }

    /// 1 → 0.45 → 1 per cycle, like the mockup's `w-pulse`. One clock for every block, so blocks
    /// created at different moments still pulse together, each row 0.12 s after the one above.
    static func opacity(at date: Date, index: Int) -> Double {
        let period = DustlingTheme.Motion.skeletonPulse
        let elapsed = date.timeIntervalSinceReferenceDate - Double(index) * DustlingTheme.Motion.skeletonStagger
        let phase = elapsed.truncatingRemainder(dividingBy: period) / period
        return 1 - 0.55 * (1 - cos(phase * 2 * .pi)) / 2
    }
}
