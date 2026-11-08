import SwiftUI

/// The 60 pt bar at the bottom of every tool screen (DESIGN-mosaic §4): the selection summary on the
/// left, buttons on the right with the primary action last.
struct ActionBar<Buttons: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var buttons: () -> Buttons

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 12) {
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
}
