import SwiftUI

/// A 20 pt status chip (DESIGN-mosaic §8): neutral, warning ("Your data", "App not found"),
/// success ("In the Trash") and admin (lock icon).
struct Chip: View {
    enum Kind {
        case neutral, warning, success, admin
    }

    let text: String
    var kind: Kind = .neutral
    /// An optional 8 pt pixel icon. Admin chips always show the lock.
    var icon: PixelIcon?
    /// Neutral and admin chips fill with `panel`. On a `panel`-coloured row that fill disappears, so
    /// such rows pass true to fill with `ground` instead. Same shape and metrics.
    var onPanel = false

    private typealias Palette = DustlingTheme.Palette

    private var foreground: Color {
        switch kind {
        case .neutral, .admin: return Palette.ink2
        case .warning: return Palette.warning
        case .success: return Palette.success
        }
    }

    private var background: Color {
        switch kind {
        case .neutral, .admin: return onPanel ? Palette.ground : Palette.panel
        case .warning: return Palette.warning.opacity(0.15)
        case .success: return Palette.success.opacity(0.15)
        }
    }

    private var shownIcon: PixelIcon? { kind == .admin ? .lock : icon }

    var body: some View {
        HStack(spacing: 4) {
            if let shownIcon {
                PixelIconView(shownIcon, color: foreground, size: .small)
            }
            Text(text)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 11).weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .frame(height: DustlingTheme.Metrics.chipHeight)
        .background(background, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HStack {
        Chip(text: "Neutral")
        Chip(text: "Your data", kind: .warning)
        Chip(text: "In the Trash", kind: .success, icon: .check)
        Chip(text: "Helper", kind: .admin)
    }
    .padding()
}
