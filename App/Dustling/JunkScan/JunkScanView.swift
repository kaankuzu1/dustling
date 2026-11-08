import DustlingAppModel
import DustlingCore
import SwiftUI

/// Junk scan (SCREENS-final §3, the "Results", "Scanning" and "Summary" frames): a header for the
/// state, the **Safe to remove** and **Review first** sections of category tiles, the Trash tile, and
/// the action bar.
struct JunkScanView: View {
    @Environment(AppModels.self) private var models
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingEmptyTrash = false

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let tiles = models.junkTiles
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScreenToolbar(title: "Junk scan", subtitle: subtitle(now: context.date)) {
                    Button(action: scanAgain) {
                        HStack(spacing: 6) {
                            PixelIconView(.refresh, color: Palette.ink)
                            Text("Scan again")
                        }
                    }
                    .disabled(models.junk.isBusy || models.places.places == nil)
                    .help("Scans the places Dustling can open again")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    sections(tiles)
                }
                .padding(.top, 12)
                .padding(.bottom, 18)
                .padding(.horizontal, DustlingTheme.Metrics.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            JunkActionBar(tiles: tiles, confirmingEmptyTrash: $confirmingEmptyTrash)
        }
        .background(Palette.ground)
        // The first visit scans like Home does (once per launch, never opening a locked place).
        .task(id: models.places.places) { models.loadHomeIfNeeded() }
        .sheet(isPresented: $confirmingEmptyTrash) { EmptyTrashSheet() }
    }

    private func scanAgain() {
        models.scanJunk()
        models.refreshTrash()
    }

    private func subtitle(now: Date) -> String {
        switch models.junk.state {
        case .idle: return "Caches, logs and other files apps rebuild"
        case .scanning: return "Scanning your Mac…"
        case .moving: return "Moving to the Trash…"
        case .done: return "Cleanup finished"
        case .ready:
            let checked = models.lastScanScope.map { $0.full.count + $0.partial.count } ?? 0
            let age = models.junk.lastScanFinishedAt.map { ScanAge.text(since: $0, now: now) } ?? "just now"
            return "Scanned \(age). \(checked) \(checked == 1 ? "place" : "places") checked"
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        switch models.junk.state {
        case .idle:
            ScanHeader(progress: nil)
        case .scanning(let progress):
            ScanHeader(progress: progress)
        case .ready, .moving:
            SelectionHeader()
        case .done(let record):
            SummaryView(record: record, confirmingEmptyTrash: $confirmingEmptyTrash, closedApps: models.junk.closedApps)
        }
    }

    // MARK: Sections

    @ViewBuilder private func sections(_ tiles: [JunkTile]) -> some View {
        let isDone: Bool = { if case .done = models.junk.state { return true } else { return false } }()
        let safe = tiles.filter { $0.section == .safe }
        let review = tiles.filter { $0.section == .review }
        if !safe.isEmpty {
            SectionHeader(
                icon: .check, title: "Safe to remove", caption: "Preselected. Apps and macOS rebuild these",
                total: JunkScreen.sectionTotal(tiles, .safe))
            TileGrid { ForEach(safe) { CategoryTile(tile: $0) } }
        }
        // The summary lists only what moved; the Trash tile is the summary's Empty Trash button then.
        if !review.isEmpty || !isDone {
            SectionHeader(
                icon: .info, title: "Review first", caption: "Unchecked. Look before you remove",
                total: JunkScreen.sectionTotal(tiles, .review))
            TileGrid {
                ForEach(review) { CategoryTile(tile: $0) }
                if !isDone { TrashTile(confirmingEmptyTrash: $confirmingEmptyTrash) }
            }
        }
    }
}

/// A section title: icon, name, a muted caption and the section's total on the right (`.sect-h`).
private struct SectionHeader: View {
    let icon: PixelIcon
    let title: String
    let caption: String
    let total: (bytes: UInt64?, isLowerBound: Bool)

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            PixelIconView(icon, color: Palette.ink)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(title)
                .font(DustlingTheme.Typography.rowTitle)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(caption)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Text(total.bytes.map { Bytes.format($0) + (total.isLowerBound ? " or more" : "") } ?? "Size unknown")
                .font(DustlingTheme.Typography.size)
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
        }
        .lineLimit(1)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .padding(.leading, 2)
    }
}

/// The 3-column tile grid with 10 pt gaps (`.tiles`).
private struct TileGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top), count: 3),
            alignment: .leading, spacing: 10, content: content)
    }
}

/// Results and moving: Mote, the selected total, the available / after / update triplet, and the
/// storage mosaic with selected categories in full colour.
private struct SelectionHeader: View {
    @Environment(AppModels.self) private var models

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let figures = models.homeFigures
        let moving: Bool = { if case .moving = models.junk.state { return true } else { return false } }()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // The mockup's 28 pt Mote at the nearest integer scale (32 pt). It chomps while moving.
                MoteView(moving ? .chomp : .idle, pixel: 2)
                (Text(Bytes.format(figures.safeJunk)).font(DustlingTheme.Typography.figure)
                 + Text(" selected").font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.medium))
                    .foregroundStyle(Palette.muted))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                Spacer(minLength: 16)
                triplet(figures)
            }
            if figures.available != nil {
                MosaicView(
                    layout: layout(figures), hovered: .constant(nil), nibbling: moving ? figures.nibbling : [],
                    unselected: Set(models.junk.categories.filter { !$0.isSelected }.map(\.id)),
                    accessibilitySummary: "Selected: \(Bytes.format(figures.safeJunk))")
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
    }

    /// Free space first, then the categories (largest first), then one hatched cell per locked place.
    private func layout(_ figures: HomeFigures) -> MosaicLayout {
        let shown = models.junkTiles.filter { $0.bytes != nil && $0.status != .cleaned }
        // One hatched cell per place with no known size: locked, unreadable, or not reached by the scan.
        let locked = models.junkTiles.filter { $0.bytes == nil && $0.status != .pending }.count
        return MosaicLayout.make(
            totalBytes: 0, availableBytes: figures.available ?? 0,
            categories: shown.map { ($0.id, $0.bytes ?? 0) }, inTrashBytes: 0, lockedPlaces: locked)
    }

    private func triplet(_ figures: HomeFigures) -> some View {
        HStack(spacing: 22) {
            tripletItem("Available now", figures.available.map { Bytes.format($0) })
            tripletItem(
                "After cleanup and Empty Trash",
                figures.afterCleanup.map { Bytes.format($0) + (figures.afterCleanupIsLowerBound ? " or more" : "") })
            tripletItem("Update needs", Bytes.format(models.goal.neededBytes))
        }
        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
        .lineLimit(1)
    }

    private func tripletItem(_ label: String, _ value: String?) -> some View {
        (Text(label + " ").foregroundStyle(Palette.muted)
         + Text(value ?? "…").fontWeight(.semibold).foregroundStyle(Palette.ink))
            .monospacedDigit()
    }
}

/// The bottom bar: the selection or progress on the left, the screen's buttons on the right with the
/// primary action last (`actJunk` in the mockups).
private struct JunkActionBar: View {
    let tiles: [JunkTile]
    @Binding var confirmingEmptyTrash: Bool

    @Environment(AppModels.self) private var models
    @State private var confirmingLimitedClean = false
    @State private var reviewingFiles = false
    /// Open apps that hold selected files: asked about before cleaning.
    @State private var closingApps: CloseAppsRun?

    private typealias Palette = DustlingTheme.Palette

    /// Open apps holding selected files are offered to close first. Without Full Disk Access the user
    /// hears first that Dustling can't put the files back (the close-apps sheet says it too).
    private func moveToTrash() {
        let holders = models.junk.openAppHolders(running: OpenApps.regular())
        if !holders.isEmpty {
            closingApps = CloseAppsRun(holders: holders)
        } else if models.junk.cleanupGate.kind == .confirmFirst {
            confirmingLimitedClean = true
        } else {
            Task { await models.cleanJunk() }
        }
    }

    var body: some View {
        let junk = models.junk
        switch junk.state {
        case .idle:
            ActionBar(title: "Not scanned yet", caption: "Nothing changes until you choose.") {
                Button("Scan") { models.scanJunk() }
                    .dustlingPrimary()
                    .disabled(models.places.places == nil)
            }
        case .scanning:
            ActionBar(title: "Scanning", caption: "Nothing changes until you choose.", busyLabel: "Scanning…") {
                Button("Stop", action: junk.stop)
            }
        case .ready:
            let gate = junk.cleanupGate
            ActionBar(
                title: JunkScreen.selectionLine(tiles, selectedBytes: models.homeFigures.safeJunk),
                caption: junk.message
                    ?? (gate.kind == .refused ? gate.note : nil)
                    ?? "Moves to the Trash. Nothing is erased until you empty it."
            ) {
                Button("Review files") { reviewingFiles = true }
                    .disabled(!junk.categories.contains { $0.isSelected && !$0.stopped })
                    .help("Lists every file that would move, so you can leave some out")
                Button(action: moveToTrash) {
                    HStack(spacing: 6) {
                        PixelIconView(.trash, color: Palette.onAccent)
                        Text("Move to Trash")
                    }
                }
                .dustlingPrimary()
                .disabled(gate.kind == .refused)
            }
            .alert(
                "Move \(Bytes.format(models.homeFigures.safeJunk)) to the Trash?",
                isPresented: $confirmingLimitedClean
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Move to Trash") { Task { await models.cleanJunk(confirmedLimited: true) } }
            } message: {
                Text(gate.note ?? "")
            }
            .sheet(isPresented: $reviewingFiles) { ReviewFilesSheet() }
            .sheet(item: $closingApps) { run in CloseAppsSheet(run: run) }
        case .moving(let done, let total, let bytes):
            ActionBar(
                title: "Moving to the Trash",
                caption: "\(done) of \(total) \(total == 1 ? "item" : "items"), \(Bytes.format(bytes)) moved",
                busyLabel: "Moving…"
            ) {
                Button("Stop", action: junk.stop)
            }
        case .done(let record):
            ActionBar(
                title: junk.restoreOutcomes.map(JunkSummary.restoreHeadline)
                    ?? "\(Bytes.format(record.bytesMovedToTrash)) in the Trash",
                caption: junk.restoreOutcomes != nil
                    ? "Scan again to see what can go now."
                    : "Available space grows when you empty the Trash."
            ) {
                Button(action: { models.scanJunk(); models.refreshTrash() }) {
                    HStack(spacing: 6) {
                        PixelIconView(.refresh, color: Palette.ink)
                        Text("Scan again")
                    }
                }
                .disabled(junk.isBusy)
                Button("Empty Trash…") { confirmingEmptyTrash = true }
                    .dustlingPrimary()
                    .disabled(!models.trash.canEmpty || models.trash.isEmptying || junk.isRestoring)
                    .help(models.trash.disabledReason ?? "Shows what is in the Trash and asks before deleting it")
            }
        }
    }
}

/// A small spinner, or under Reduce Motion the static label (DESIGN-mosaic §9).
struct BusyIndicator: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(label)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                .foregroundStyle(DustlingTheme.Palette.muted)
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(label)
        }
    }
}
