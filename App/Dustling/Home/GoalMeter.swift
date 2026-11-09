import DustlingAppModel
import DustlingCore
import SwiftUI

/// The goal meter under the hero buttons (`goalMeter` in the approved mockups): 45 segments, a
/// marker at the update size, and the legend. "Check update size" sits at the end of the legend
/// (Ruling R32).
struct GoalMeterView: View {
    let available: Int64
    let afterCleanup: Int64
    /// The Trash couldn't be read in full: the after-cleanup figure is at least this.
    var afterCleanupIsLowerBound = false
    let needed: Int64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The loading skeleton: the bar and legend as blocks, no marker.
    @Environment(\.skeletonIndex) private var skeletonIndex
    private var isSkeleton: Bool { skeletonIndex != nil }

    private typealias Palette = DustlingTheme.Palette

    /// `color-mix(in oklab, var(--c3) 85%, var(--bg))` in the mockup.
    static let afterCleanupColor = DustlingTheme.Series.c3.color.opacity(0.85)

    var body: some View {
        let meter = GoalMeter.make(available: available, afterCleanup: afterCleanup, needed: needed)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Array(meter.segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(Palette.ground)
                        .overlay(Rectangle().fill(color(segment)))
                }
            }
            .frame(height: 18)
            .skeletonBlock(cornerRadius: 2)
            .overlay(alignment: .topLeading) { if !isSkeleton { marker(meter.markerFraction) } }
            .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.meter, reduceMotion: reduceMotion), value: meter)
            .accessibilityElement()
            .accessibilityLabel(
                "Available now \(Bytes.format(available)), after junk cleanup and Empty Trash \(Bytes.format(afterCleanup)), the update needs \(Bytes.format(needed))")

            HStack(spacing: 14) {
                legend("Available now", Bytes.format(available), color: Palette.accent)
                legend(
                    "After junk cleanup and Empty Trash",
                    Bytes.format(afterCleanup) + (afterCleanupIsLowerBound ? " or more" : ""),
                    color: Self.afterCleanupColor)
                Spacer(minLength: 8)
                UpdateCheckControl()
            }
        }
    }

    private func color(_ segment: GoalMeter.Segment) -> Color {
        switch segment {
        case .available: Palette.accent
        case .afterCleanup: Self.afterCleanupColor
        case .empty: Palette.line
        }
    }

    /// A 2 pt ink line 6 pt past the meter on both sides, labelled "Update, 30 GB" above.
    private func marker(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            let x = (proxy.size.width * fraction).rounded()
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Palette.ink)
                    .frame(width: 2, height: proxy.size.height + 12)
                    .offset(x: x, y: -6)
                Text("Update, \(Bytes.format(needed))")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 11).weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                    .fixedSize()
                    .offset(x: x - 14, y: -20)
            }
        }
        .accessibilityHidden(true)
    }

    private func legend(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                .skeletonBlock(cornerRadius: 2)
            (Text(label + " ").foregroundStyle(Palette.muted)
             + Text(value).fontWeight(.semibold).foregroundStyle(Palette.ink))
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .skeletonText()
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Check update size" (Ruling R32). It runs `softwareupdate --list` only when clicked, off the main
/// actor, and shows a cancellable "Checking…" state while it waits.
struct UpdateCheckControl: View {
    @Environment(AppModels.self) private var models
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let check = models.updateCheck
        HStack(spacing: 8) {
            switch check.state {
            case .checking:
                if !reduceMotion {
                    ProgressView().controlSize(.mini)
                }
                Text("Checking…").foregroundStyle(Palette.muted)
                Button("Cancel", action: check.cancel)
                    .buttonStyle(.link)
                    // The window's ink would otherwise win over the link colour.
                    .foregroundStyle(Palette.accent)
            case .noUpdate:
                Text("No macOS update is waiting").foregroundStyle(Palette.muted)
                link("Check again", check)
            case .failed(let reason):
                Text("Couldn't check the update size: \(reason)")
                    .foregroundStyle(Palette.warning)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
                link("Try again", check)
            case .idle, .measured:
                link("Check update size", check)
            }
        }
        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
    }

    private func link(_ title: String, _ check: UpdateSizeCheck) -> some View {
        Button(title, action: check.start)
            .buttonStyle(.link)
            .foregroundStyle(Palette.accent)
            .help("Asks Software Update how big the pending macOS update is. This contacts Apple.")
    }
}
