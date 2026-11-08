import DustlingAppModel
import DustlingCore
import SwiftUI

/// The three tool cards under the mosaic (`toolCards` in the approved mockups): Junk scan,
/// Uninstaller and Startup items, each with its figure, one line and a button.
struct ToolCardRow: View {
    @Binding var hovered: HomeLink?
    @Environment(AppModels.self) private var models

    var body: some View {
        let figures = models.homeFigures
        HStack(alignment: .top, spacing: 14) {
            ToolCard(
                icon: .shell(.broom), series: .c1, title: "Junk scan",
                text: figures.scanFinished
                    ? ToolCards.junk(safeBytes: figures.safeJunk, reviewBytes: figures.reviewJunk, shortfall: figures.shortfall)
                    : nil,
                button: "Review junk", primary: true, highlighted: hovered == .junk
            ) { models.selection = .junkScan }
            .onHover { inside in
                if inside { hovered = .junk } else if hovered == .junk { hovered = nil }
            }

            ToolCard(
                icon: .theme(.apps), series: .c4, title: "Uninstaller",
                text: uninstallerText, note: uninstallerNote,
                button: "Choose apps"
            ) { models.selection = .uninstaller }

            ToolCard(
                icon: .theme(.power), series: .c5, title: "Startup items",
                text: startupText,
                button: "Review items"
            ) { models.selection = .startupItems }
        }
    }

    private var uninstallerText: ToolCardText? {
        let model = models.uninstaller
        guard models.uninstallerCounted, !model.isLoading else { return nil }
        return ToolCards.uninstaller(model.apps, now: .now)
    }

    /// Without Full Disk Access the uninstaller doesn't look for leftovers (it would ask for access
    /// to other apps' data), so the card says why instead of loading forever.
    private var uninstallerNote: String? {
        models.health.fullDiskAccess == .granted ? nil : "Needs Full Disk Access to look for leftovers"
    }

    private var startupText: ToolCardText? {
        let model = models.startup
        guard models.startupLoaded, !model.isLoading else { return nil }
        return ToolCards.startup(model.items, orphanCount: model.orphanBanner?.items.count ?? 0)
    }
}

/// One tool card: icon tile and title, the figure in Geist Pixel, one line, and a small button.
struct ToolCard: View {
    enum Icon {
        case theme(PixelIcon)
        case shell(ShellPixelIcon)
    }

    let icon: Icon
    let series: DustlingTheme.Series
    let title: String
    /// nil while loading: the figure and line show as skeletons.
    let text: ToolCardText?
    /// Shown instead of the figure and line when the tool can't count yet.
    var note: String?
    let button: String
    var primary = false
    var highlighted = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias Palette = DustlingTheme.Palette

    /// What the loading skeleton stands in for: a figure and a one-line sentence.
    private static let placeholder = ToolCardText(figure: "00.0 GB", line: Placeholder.text(0, base: 26, spread: 0))

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                iconTile
                Text(title)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 14).weight(.semibold))
                    .foregroundStyle(Palette.ink)
            }
            if let note {
                Text(note)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // While loading, the same two lines with placeholder text, drawn as the skeleton.
                let shown = text ?? Self.placeholder
                Text(shown.figure)
                    .font(DustlingTheme.Typography.figure)
                    .foregroundStyle(Palette.ink)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .skeletonText()
                    .skeleton(text == nil)
                Text(shown.line)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .skeletonText()
                    .skeleton(text == nil, index: 1)
            }
            let button = Button(self.button, action: action).controlSize(.small)
            if primary {
                button.dustlingPrimary()
            } else {
                button
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            highlighted ? Palette.rowSelection : Palette.panel,
            in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
        .skeletonSurfaceIsPanel()
        .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.hover, reduceMotion: reduceMotion), value: highlighted)
        .accessibilityElement(children: .contain)
    }

    /// 30 pt tile of the category colour at 17% over `ground`, the icon at the full colour.
    private var iconTile: some View {
        RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
            .fill(Palette.ground)
            .overlay(
                RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
                    .fill(series.color.opacity(0.17)))
            .frame(width: DustlingTheme.Metrics.iconTile, height: DustlingTheme.Metrics.iconTile)
            .overlay {
                switch icon {
                case .theme(let icon): PixelIconView(icon, color: series.color)
                case .shell(let icon): PixelIconView(icon, color: series.color)
                }
            }
            .accessibilityHidden(true)
    }
}
