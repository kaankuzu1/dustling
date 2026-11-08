import SwiftUI

/// A `panel`-coloured placeholder block in the shape of content that is still loading
/// (DESIGN-mosaic §8). It pulses in opacity only, over 1.3 s, staggered 0.12 s per row.
/// Under Reduce Motion or while the window isn't key it stays still.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var cornerRadius: CGFloat = DustlingTheme.Metrics.controlRadius
    /// The row index, used for the stagger.
    var index: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var start = Date.now

    var body: some View {
        Group {
            if !reduceMotion && controlActiveState == .key {
                TimelineView(.periodic(from: start, by: 1.0 / 30)) { context in
                    block.opacity(opacity(at: context.date))
                }
            } else {
                block
            }
        }
        .accessibilityHidden(true)
    }

    private var block: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(DustlingTheme.Palette.panel)
            .frame(width: width, height: height)
    }

    /// 1 → 0.45 → 1 per cycle, like the mockup's `w-pulse`.
    private func opacity(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(start) - Double(index) * DustlingTheme.Motion.skeletonStagger
        guard elapsed > 0 else { return 1 }
        let phase = elapsed.truncatingRemainder(dividingBy: DustlingTheme.Motion.skeletonPulse)
            / DustlingTheme.Motion.skeletonPulse
        return 1 - 0.55 * (1 - cos(phase * 2 * .pi)) / 2
    }
}

/// A skeleton in the shape of a list row: icon tile, title and caption, size on the right.
struct SkeletonRow: View {
    var index: Int = 0

    var body: some View {
        HStack(spacing: DustlingTheme.Metrics.columnGap) {
            SkeletonBlock(width: DustlingTheme.Metrics.iconTile, height: DustlingTheme.Metrics.iconTile, index: index)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: 180, height: 11, index: index)
                SkeletonBlock(width: 260, height: 9, index: index)
            }
            Spacer(minLength: 0)
            SkeletonBlock(width: 56, height: 11, index: index)
        }
        .padding(DustlingTheme.Metrics.rowPadding)
        .frame(minHeight: DustlingTheme.Metrics.rowMinHeight)
    }
}

#Preview {
    VStack(spacing: 0) {
        ForEach(0..<4, id: \.self) { SkeletonRow(index: $0) }
    }
    .frame(width: 600)
    .padding()
}
