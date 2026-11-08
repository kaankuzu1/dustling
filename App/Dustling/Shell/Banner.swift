import SwiftUI

/// An inline banner at the top of a screen's content, never a modal (DESIGN-mosaic §8): the issue in
/// bold, one plain sentence of cause, and at most two buttons with the fix last and primary.
struct Banner<Buttons: View>: View {
    enum Tone {
        /// A problem or something that needs the user. The default.
        case warning
        /// Neutral information, such as purgeable space.
        case info
        /// Something finished well.
        case success
    }

    enum Leading {
        case none
        /// The worried Mote, for problems (30 pt wide in the mockups; 32 pt at an integer scale).
        case worriedMote
        case icon(PixelIcon)
    }

    let title: String
    let message: String
    var tone: Tone = .warning
    var leading: Leading = .none
    @ViewBuilder var buttons: () -> Buttons

    private typealias Palette = DustlingTheme.Palette

    private var toneColor: Color {
        switch tone {
        case .warning: return Palette.warning
        case .info: return Palette.accent
        case .success: return Palette.success
        }
    }

    private var fillOpacity: Double {
        switch tone {
        case .warning: return 0.09
        case .info: return 0.07
        case .success: return 0.08
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            switch leading {
            case .none: EmptyView()
            case .worriedMote: MoteView(.worried, pixel: 2)
            case .icon(let icon): PixelIconView(icon, color: toneColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DustlingTheme.Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                Text(message)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            HStack(spacing: 8) { buttons() }
                .controlSize(.small)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background {
            RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous)
                .fill(Palette.ground)
                .overlay(
                    RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous)
                        .fill(toneColor.opacity(fillOpacity)))
                .overlay(
                    RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous)
                        .strokeBorder(toneColor.opacity(0.3), lineWidth: 1))
        }
    }
}

extension Banner where Buttons == EmptyView {
    init(title: String, message: String, tone: Tone = .warning, leading: Leading = .none) {
        self.init(title: title, message: message, tone: tone, leading: leading) { EmptyView() }
    }
}

#Preview {
    VStack(spacing: 12) {
        Banner(
            title: "The helper isn't responding, so launch daemons can't be changed.",
            message: "Dustling tried to register it again and that didn't work.",
            leading: .worriedMote
        ) {
            Button("View log") {}
            Button("Repair helper") {}.dustlingPrimary()
        }
        Banner(title: "Purgeable space", message: "macOS frees this on its own.", tone: .info, leading: .icon(.info))
    }
    .padding()
    .frame(width: 800)
}
