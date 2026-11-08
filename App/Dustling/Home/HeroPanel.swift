import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// The Home hero (`homeHero` in the approved mockups): Mote, the update goal headline, a caption,
/// **Clean up junk** and **Empty Trash… N GB**, and the goal meter. When the goal is met: happy Mote,
/// "Ready for the macOS update", **Open Software Update** and **View this cleanup**.
struct HeroPanel: View {
    @Binding var hovered: HomeLink?
    @Binding var confirmingEmptyTrash: Bool

    @Environment(AppModels.self) private var models
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let figures = models.homeFigures
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                // The mockup's 72 pt Mote, drawn at the nearest integer scale (64 pt).
                MoteView(mood(figures), pixel: 4)
                VStack(alignment: .leading, spacing: 4) {
                    headline(figures)
                    caption(figures)
                    buttons(figures)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .needMore = figures.hero, let available = figures.available, let after = figures.afterCleanup {
                GoalMeterView(
                    available: available, afterCleanup: after, afterCleanupIsLowerBound: figures.afterCleanupIsLowerBound,
                    needed: models.goal.neededBytes)
                    .padding(.top, 18)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
    }

    private func mood(_ figures: HomeFigures) -> MoteView.Mood {
        if case .moving = models.junk.state { return .chomp }
        if case .goalMet = figures.hero { return .happy }
        return .idle
    }

    // MARK: Headline and caption

    @ViewBuilder private func headline(_ figures: HomeFigures) -> some View {
        if let hero = figures.hero {
            Text(hero.headline)
                .font(.custom(DustlingTheme.Typography.pixelFamily, size: 22))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.meter, reduceMotion: reduceMotion), value: hero)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        } else if let problem = models.storage.problems.first {
            // The storage read failed: say so instead of showing a made-up number.
            Text(problem)
                .font(DustlingTheme.Typography.rowTitle)
                .foregroundStyle(Palette.warning)
        } else {
            SkeletonBlock(width: 420, height: 22)
        }
    }

    @ViewBuilder private func caption(_ figures: HomeFigures) -> some View {
        switch figures.hero {
        case .goalMet(let available):
            HStack(spacing: 10) {
                captionText(HomeHero.goalMetCaption(available: available, needed: models.goal.neededBytes))
                UpdateCheckControl()
            }
        case .needMore(let shortfall):
            if !figures.scanFinished {
                SkeletonBlock(width: 300, height: 12, index: 1)
            } else if let junk = HomeHero.junkCaption(safeJunk: figures.safeJunk, shortfall: shortfall) {
                captionText(junk)
            }
        case nil:
            EmptyView()
        }
    }

    private func captionText(_ caption: HomeHero.Caption) -> some View {
        (Text(caption.bold).font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
            .foregroundStyle(Palette.ink)
         + Text(caption.rest).font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
            .foregroundStyle(Palette.muted))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
    }

    // MARK: Buttons

    @ViewBuilder private func buttons(_ figures: HomeFigures) -> some View {
        HStack(spacing: 12) {
            if case .goalMet = figures.hero {
                Button("Open Software Update", action: openSoftwareUpdate)
                    .dustlingPrimary()
                if case .done = models.junk.state {
                    Button("View this cleanup") { models.selection = .history }
                }
            } else {
                Button { models.selection = .junkScan } label: {
                    HStack(spacing: 6) {
                        PixelIconView(.broom, color: Palette.onAccent)
                        Text("Clean up junk")
                    }
                }
                .dustlingPrimary()
                emptyTrashButton(figures)
            }
        }
    }

    private func emptyTrashButton(_ figures: HomeFigures) -> some View {
        let trash = models.trash
        // The size only when the whole Trash was read; a lower bound would misstate what gets deleted.
        let size = figures.trashIsLowerBound ? nil : figures.trashBytes
        let title = size.map { "Empty Trash… \(Bytes.format($0))" } ?? "Empty Trash…"
        return Button(title) { confirmingEmptyTrash = true }
            .monospacedDigit()
            // Hover link from the mosaic's "in Trash" cells (DESIGN-mosaic §5).
            .overlay {
                RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius + 1, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .padding(-3)
                    .opacity(hovered == .trash ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.hover, reduceMotion: reduceMotion), value: hovered)
            .disabled(!trash.canEmpty || trash.isEmptying)
            .help(trash.disabledReason ?? "Shows what is in the Trash and asks before deleting it")
            .onHover { inside in
                if inside { hovered = .trash } else if hovered == .trash { hovered = nil }
            }
    }
}

/// Opens System Settings > General > Software Update. Says so if it doesn't open.
@MainActor
func openSoftwareUpdate() {
    let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
    if !NSWorkspace.shared.open(url) {
        NSLog("Dustling: couldn't open System Settings at \(url)")
        let alert = NSAlert()
        alert.messageText = "System Settings didn't open"
        alert.informativeText = "Open System Settings yourself, then go to General > Software Update."
        alert.runModal()
    }
}
