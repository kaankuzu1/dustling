import SwiftUI

/// Step 1 (O10 "Trust first" in the Stepper frame): Mote, the headline, one line of trust, what
/// Dustling can and never touches, and Get started.
struct WelcomeStep: View {
    @Environment(AppModels.self) private var models

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 96 pt (6 pt per pixel): the integer scale the design chose for the mockups' 72 pt Mote.
            MoteView(.idle, pixel: 6)
            StepHeadline(
                title: "Let Dustling look in your Library",
                caption: "Open source, nothing leaves your Mac, and everything goes to the Trash first.",
                small: false, captionSize: 14)
            TrustColumns()
            HStack(spacing: 12) {
                Button("Get started") {
                    models.onboarding.complete(.welcome)
                    models.onboarding.step = .fullDiskAccess
                }
                    .dustlingPrimary()
                    .keyboardShortcut(.defaultAction)
                Text("Takes about a minute.")
                    .font(OnboardingType.caption())
                    .foregroundStyle(DustlingTheme.Palette.muted)
            }
        }
    }
}

/// The two trust panels: what Dustling can clean and what it never touches.
struct TrustColumns: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TrustPanel(
                icon: .check, iconColor: DustlingTheme.Palette.success, title: "Dustling can clean",
                items: ["Caches and logs apps rebuild", "Leftovers of apps you remove", "Startup items you turn off"])
            TrustPanel(
                icon: .lock, iconColor: DustlingTheme.Palette.warning, title: "Dustling never touches",
                items: ["Documents, Photos and Desktop", "Passwords, cookies and history", "Anything without your OK"])
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TrustPanel: View {
    let icon: PixelIcon
    let iconColor: Color
    let title: String
    let items: [String]
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PixelIconView(icon, color: iconColor)
                Text(title)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.semibold))
                    .foregroundStyle(Palette.ink)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").accessibilityHidden(true)
                        Text(item)
                    }
                }
            }
            .padding(.leading, 4)
            .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
            .foregroundStyle(Palette.ink2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
