import SwiftUI

/// The 56 pt bar at the top of the content (SCREENS-final, Shell): the window title in Geist Pixel
/// 16 pt and a subtitle on the left, the screen's tools on the right.
struct ScreenToolbar<Tools: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var tools: () -> Tools

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DustlingTheme.Typography.windowTitle)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            HStack(spacing: 8) { tools() }
        }
        .padding(.horizontal, DustlingTheme.Metrics.gutter)
        .frame(height: DustlingTheme.Metrics.toolbarHeight)
        .frame(maxWidth: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

extension ScreenToolbar where Tools == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
