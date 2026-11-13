import SwiftUI

/// The 60 pt bar at the bottom of every tool screen (DESIGN-mosaic §4): the selection summary on the
/// left, buttons on the right with the primary action last.
struct ActionBar<Buttons: View>: View {
    let title: String
    var caption: String?
    /// While work runs: a spinner before the summary (a static label under Reduce Motion).
    var busyLabel: String?
    @ViewBuilder var buttons: () -> Buttons

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 12) {
            if let busyLabel { BusyIndicator(label: busyLabel) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13.5).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                        .foregroundStyle(Palette.muted)
                        .contentTransition(.numericText())
                }
            }
            .lineLimit(1)
            .monospacedDigit()
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            HStack(spacing: 8) { buttons() }
        }
        .padding(.horizontal, DustlingTheme.Metrics.gutter)
        .frame(height: DustlingTheme.Metrics.actionBarHeight)
        .frame(maxWidth: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .top) { Hairline() }
    }
}

extension ActionBar where Buttons == EmptyView {
    init(title: String, caption: String? = nil) {
        self.init(title: title, caption: caption) { EmptyView() }
    }
}

/// A small spinner with its text beside it, for work that waits where a bar has no room for a title
/// ("Waiting for your Mac password"). Under Reduce Motion only the text.
struct BusyLabel: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if !reduceMotion {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                .foregroundStyle(DustlingTheme.Palette.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A 1 pt `line`-coloured rule.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(DustlingTheme.Palette.line)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The one primary button per view: a standard bordered button filled with `accentFill`
    /// (DESIGN-mosaic §8). The label colour is the system's text-on-prominent, white.
    func dustlingPrimary() -> some View {
        buttonStyle(.borderedProminent)
            .tint(DustlingTheme.Palette.accentFill)
    }

    /// `dustlingPrimary()` only while `isPrimary`, for a button that stops being the next step.
    @ViewBuilder func dustlingPrimary(if isPrimary: Bool) -> some View {
        if isPrimary { dustlingPrimary() } else { self }
    }
}
