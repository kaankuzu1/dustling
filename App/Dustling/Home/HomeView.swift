import DustlingAppModel
import DustlingCore
import SwiftUI

/// Home (SCREENS-final §2, the "Home" and "After cleanup: goal met" frames): the hero with the
/// update goal, the mosaic of everything Dustling could reclaim, and the three tool cards.
struct HomeView: View {
    @Environment(AppModels.self) private var models
    /// The hover link between the mosaic and the tools (DESIGN-mosaic §5).
    @State private var hovered: HomeLink?
    @State private var confirmingEmptyTrash = false

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(spacing: 0) {
            // Redrawn every 30 s so "2 minutes ago" stays true.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScreenToolbar(title: "Home", subtitle: subtitle(now: context.date)) {
                    Button(action: models.reloadHome) {
                        HStack(spacing: 6) {
                            PixelIconView(.refresh, tint: .foreground)
                            Text("Scan again")
                        }
                    }
                    .disabled(models.junk.isBusy || !models.homeLoaded)
                    .help("Scans for junk again and re-reads the Trash, apps and startup items")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    banners
                    HeroPanel(hovered: $hovered, confirmingEmptyTrash: $confirmingEmptyTrash)
                    if let notice = PurgeableNotice.make(storage: models.storage.info) {
                        PurgeableBanner(notice: notice)
                    }
                    if !isGoalMet {
                        ReclaimablePanel(hovered: $hovered)
                    }
                    ToolCardRow(hovered: $hovered)
                }
                .padding(.vertical, 18)
                .padding(.horizontal, DustlingTheme.Metrics.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.ground)
        .task(id: models.places.places) {
            models.loadHomeIfNeeded()
            models.rescanIfPlacesOpened()
        }
        .task(id: models.fullDiskAccessKey) {
            guard models.homeLoaded else { return }
            models.loadUninstallerIfAllowed()
            models.refreshTrash()
        }
        .dismissedOnQuit($confirmingEmptyTrash)
        .sheet(isPresented: $confirmingEmptyTrash) {
            EmptyTrashSheet()
        }
    }

    private var isGoalMet: Bool {
        if case .goalMet = models.homeFigures.hero { return true }
        return false
    }

    // MARK: Banners

    /// Limited mode first (Full Disk Access off), then places that can't be read for another reason.
    @ViewBuilder private var banners: some View {
        if LimitedModeBanner.isShown(models) {
            LimitedModeBanner()
        }
        if let sentence = models.places.unreadableSentence {
            Banner(title: sentence, message: LimitedModeBanner.honesty, leading: .icon(.warn))
        }
        if let problem = models.settings.loadProblem {
            Banner(title: "Scan settings were reset", message: problem, leading: .icon(.warn))
        }
    }

    // MARK: Subtitle

    private func subtitle(now: Date) -> String {
        if LimitedModeBanner.isShown(models) {
            return LimitedModeBanner.subtitle(lockedCount: models.places.lockedPlaces.count)
        }
        switch models.junk.state {
        case .scanning: return "Scanning your Mac…"
        case .moving: return "Moving to the Trash…"
        case .done(let record): return "Cleanup finished \(ScanAge.text(since: record.startedAt, now: now))"
        default: break
        }
        if let finished = models.junk.lastScanFinishedAt {
            return "Last scan \(ScanAge.text(since: finished, now: now))"
        }
        return "Free space and what Dustling can reclaim"
    }
}

/// The mosaic panel: "N GB Dustling could reclaim. Each pixel is a quarter gigabyte."
private struct ReclaimablePanel: View {
    @Binding var hovered: HomeLink?
    @Environment(AppModels.self) private var models

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let figures = models.homeFigures
        VStack(alignment: .leading, spacing: 8) {
            // While the scan runs: the same caption with a placeholder size, and the mosaic's skeleton.
            let finished = figures.scanFinished
            (Text(finished ? figures.reclaimable.map(Bytes.format) ?? "" : "00.0 GB")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
                .foregroundStyle(Palette.ink)
             + Text("\(finished && figures.isLowerBound ? " or more" : "") Dustling could reclaim. Each pixel is a quarter gigabyte.")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                .foregroundStyle(Palette.muted))
                .monospacedDigit()
                .skeletonText()
                .skeleton(!finished)
            if finished {
                MosaicView(
                    layout: figures.mosaic, hovered: $hovered, nibbling: figures.nibbling,
                    accessibilitySummary: figures.mosaicSummary)
            } else {
                MosaicSkeleton(index: 1)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
        .skeletonSurfaceIsPanel()
    }
}
