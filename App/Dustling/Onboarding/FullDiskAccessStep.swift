import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI
import UniformTypeIdentifiers

/// Step 2 (O06 "See what's hidden" and O05 "Drag to grant" in the Stepper frame): how many places
/// Dustling can see, the locked mosaic, two ways to grant Full Disk Access, and the live status line.
struct FullDiskAccessStep: View {
    @Environment(AppModels.self) private var models
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias Palette = DustlingTheme.Palette

    private var isGranted: Bool { models.health.fullDiskAccess == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            OnboardingPanel { PlacesMosaic(places: models.places.places) }
            if isGranted {
                Banner(
                    title: "Full Disk Access is on.",
                    message: "Dustling checked by reading a protected folder.",
                    tone: .success, leading: .icon(.check))
                Button("Continue") { models.onboarding.step = .permissions }
                    .dustlingPrimary()
                    .keyboardShortcut(.defaultAction)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    OnboardingPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Open System Settings")
                                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13.5).weight(.semibold))
                            Text("Switch Dustling on under Privacy & Security, Full Disk Access.")
                                .font(OnboardingType.caption())
                                .foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            OpenSettingsButton()
                        }
                    }
                    .frame(maxHeight: .infinity)
                    DragTile()
                        .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                statusLine
                Button("Skip for now") { models.onboarding.step = .permissions }
            }
        }
        .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.toggle, reduceMotion: reduceMotion), value: isGranted)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 12) {
            // The mockup draws Mote 40 pt wide; integer scales give 32 or 48, so 48 (3 pt per pixel).
            MoteView(models.places.places != nil && models.places.lockedPlaces.isEmpty ? .happy : .worried, pixel: 3)
            if models.places.places == nil {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 320, height: 22)
                    SkeletonBlock(width: 420, height: 12, index: 1)
                }
                .accessibilityElement()
                .accessibilityLabel("Checking which places Dustling can see")
            } else if models.places.lockedPlaces.isEmpty {
                StepHeadline(
                    title: "Dustling can see everything now",
                    caption: "All \(models.places.total) places are open.")
            } else {
                StepHeadline(
                    title: "Dustling can see \(models.places.readableCount) of \(models.places.total) places",
                    caption: "The hatched pixels are junk in folders macOS protects. Full Disk Access opens them.")
            }
        }
    }

    /// "Waiting for access…" while polling. If no probe target could decide, say that instead of waiting
    /// silently forever.
    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 10) {
            if models.hasProbedFullDiskAccess && models.health.fullDiskAccess == .unknown {
                PixelIconView(.warn, color: Palette.warning)
                Text("Couldn't verify Full Disk Access")
            } else {
                if !reduceMotion {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text("Waiting for access. Dustling notices on its own, no restart needed.")
            }
        }
        .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
        .foregroundStyle(Palette.muted)
        .accessibilityElement(children: .combine)
    }
}

/// The dashed drag tile: drag the app icon into the Full Disk Access list in System Settings.
/// The drag carries Dustling's own bundle URL as a file URL.
private struct DragTile: View {
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 12) {
            AppIconTile(size: 44)
                .onDrag {
                    NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                } preview: {
                    AppIconTile(size: 44)
                }
                .help("Drag Dustling into the Full Disk Access list")
            VStack(alignment: .leading, spacing: 4) {
                Text("Or drag Dustling into the list")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13.5).weight(.semibold))
                Text("Works in the same Full Disk Access panel.")
                    .font(OnboardingType.caption())
                    .foregroundStyle(Palette.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            shape.fill(Palette.ground)
                .overlay(shape.fill(Palette.accent.opacity(0.06)))
                .overlay(shape.strokeBorder(
                    Palette.accent.opacity(0.6),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag the Dustling icon into the Full Disk Access list in System Settings")
    }
}

/// The locked mosaic: every place Dustling scans as a block of 4 x 4 cells, in catalog order. Places it
/// can read show their category colour; locked places are hatched. Nothing here claims a size: Dustling
/// can't measure a place it can't open, so every block is the same.
struct PlacesMosaic: View {
    let places: [Place]?

    private static let rows = MosaicLayout.rowCount
    private static let columnsPerPlace = 4
    private static let placeholderCount = JunkCategoryID.allCases.count

    private var columns: Int { (places?.count ?? Self.placeholderCount) * Self.columnsPerPlace }

    var body: some View {
        let places = self.places
        let columns = self.columns
        Color.clear
            .aspectRatio(CGFloat(columns) / CGFloat(Self.rows), contentMode: .fit)
            .overlay {
                Canvas { context, size in
                    Self.draw(places, columns: columns, in: &context, size: size)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let places else { return "Checking which places Dustling can see" }
        let locked = places.filter { $0.access == .locked }
        guard !locked.isEmpty else { return "All \(places.count) places are open" }
        return "\(places.count - locked.count) of \(places.count) places open. Locked: "
            + locked.map(\.nameInSentence).joined(separator: ", ")
    }

    private static func draw(_ places: [Place]?, columns: Int, in context: inout GraphicsContext, size: CGSize) {
        let gap = DustlingTheme.Metrics.mosaicGap
        let cell = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        guard cell > 0 else { return }
        for column in 0..<columns {
            let place = places?[column / columnsPerPlace]
            for row in 0..<rows {
                let rect = CGRect(
                    x: CGFloat(column) * (cell + gap), y: CGFloat(row) * (cell + gap),
                    width: cell, height: cell)
                switch place?.access {
                case nil:
                    context.fill(Path(rect), with: .color(DustlingTheme.Palette.line))
                case .readable:
                    context.fill(Path(rect), with: .color(color(for: place!.id)))
                case .locked:
                    drawHatch(in: rect, context: &context)
                }
            }
        }
    }

    private static func color(for id: JunkCategoryID) -> Color {
        guard let slot = CategorySeries.slot(for: id), let series = DustlingTheme.Series(rawValue: slot - 1) else {
            // The Trash is never a category colour (DESIGN-mosaic §2).
            return DustlingTheme.Palette.neutralCell
        }
        return series.color
    }

    /// The mockups' `.lk` cell: `line` stripes, 2 pt wide every 5 pt at 135°, over `panel`.
    private static func drawHatch(in rect: CGRect, context: inout GraphicsContext) {
        context.fill(Path(rect), with: .color(DustlingTheme.Palette.panel))
        var layer = context
        layer.clip(to: Path(rect))
        let step = 5 * 2.squareRoot()
        var stripes = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            stripes.move(to: CGPoint(x: x, y: rect.maxY))
            stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        layer.stroke(stripes, with: .color(DustlingTheme.Palette.line), lineWidth: 2)
    }
}
