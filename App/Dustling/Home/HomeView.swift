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
                            PixelIconView(.refresh, color: Palette.ink)
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
        .task(id: models.places.places) { models.loadHomeIfNeeded() }
        .task(id: models.fullDiskAccessKey) {
            if models.homeLoaded { models.loadUninstallerIfAllowed() }
        }
        .sheet(isPresented: $confirmingEmptyTrash) {
            EmptyTrashSheet()
        }
    }

    private var isGoalMet: Bool {
        guard let info = models.storage.info else { return false }
        if case .goalMet = HomeHero.make(available: info.availableForImportantUsage, goal: models.goal) { return true }
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
        let figures = HomeFigures(models)
        VStack(alignment: .leading, spacing: 8) {
            if figures.scanFinished {
                (Text(figures.reclaimable.map(Bytes.format) ?? "")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                 + Text("\(figures.partial ? " or more" : "") Dustling could reclaim. Each pixel is a quarter gigabyte.")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.muted))
                    .monospacedDigit()
                MosaicView(
                    layout: figures.mosaic, hovered: $hovered, nibbling: figures.nibbling,
                    accessibilitySummary: figures.mosaicSummary)
            } else {
                SkeletonBlock(width: 320, height: 12)
                SkeletonBlock(height: 54, cornerRadius: 4, index: 1)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
    }
}

/// Home's numbers, read from the shared models in one place.
@MainActor
struct HomeFigures {
    /// `volumeAvailableCapacityForImportantUsage`, what the macOS updater counts. nil until read.
    let available: Int64?
    let hero: HomeHero?
    /// True once a scan has finished (completed or stopped) and no scan is running.
    let scanFinished: Bool
    /// Some category was only partly scanned, so totals are a lower bound.
    let partial: Bool
    let safeJunk: UInt64
    let reviewJunk: UInt64
    /// Everything in the Trash; nil while unread or unreadable.
    let trashBytes: UInt64?
    let reclaimable: UInt64?
    let mosaic: MosaicLayout
    let mosaicSummary: String
    /// Categories whose cells nibble away while a cleanup moves them.
    let nibbling: Set<JunkCategoryID>

    init(_ models: AppModels) {
        let junk = models.junk
        available = models.storage.info?.availableForImportantUsage
        hero = available.map { HomeHero.make(available: $0, goal: models.goal) }
        var finished = false
        var cleaned: Set<JunkCategoryID> = []
        var moving: Set<JunkCategoryID> = []
        let selected = Set(junk.categories.filter { $0.isSelected && !$0.stopped }.map(\.id))
        switch junk.state {
        case .ready, .problem: finished = true
        case .done:
            finished = true
            // What the cleanup moved is in the Trash now and counts there.
            cleaned = selected
        case .moving:
            finished = true
            moving = selected
        case .idle, .scanning: break
        }
        scanFinished = finished
        partial = junk.categories.contains { $0.stopped }
        let open = junk.categories.filter { !cleaned.contains($0.id) }
        safeJunk = cleaned.isEmpty ? junk.selectedBytes : 0
        reviewJunk = open.filter { $0.selection == .review }.reduce(0) { $0 + $1.bytes }
        if let contents = models.trash.contents, contents.issues.isEmpty {
            trashBytes = contents.size.bytes
        } else {
            trashBytes = nil
        }
        let places = models.places.places
        mosaic = HomeMosaic.layout(tiles: junk.categories, excluding: cleaned, trashBytes: trashBytes, places: places)
        let reclaim = HomeMosaic.reclaimableBytes(tiles: junk.categories, excluding: cleaned, trashBytes: trashBytes)
        reclaimable = finished ? reclaim : nil
        mosaicSummary = HomeMosaic.accessibilitySummary(
            reclaimable: reclaim, categories: open.filter { $0.bytes > 0 }.count,
            locked: HomeMosaic.lockedCount(places: places, trashReadable: trashBytes != nil))
        nibbling = moving
    }

    var shortfall: Int64 {
        if case .needMore(let shortfall) = hero { return shortfall }
        return 0
    }
}
