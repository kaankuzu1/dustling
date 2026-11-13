import DustlingAppModel
import DustlingCore
import SwiftUI

/// One category tile (`tile()` in the mockups): checkbox and name, the size in Geist Pixel, a mini
/// mosaic of its cells and a one-line note. Unselected and review tiles are outlined.
///
/// While moving, selected tiles show a spinner, then a check, and their cells nibble away. Locked
/// places show the lock and one hatched cell, never a size.
struct CategoryTile: View {
    let tile: JunkTile

    @Environment(AppModels.self) private var models
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Palette = DustlingTheme.Palette

    /// The place is still being scanned: the tile draws as its own skeleton.
    private var isPending: Bool { tile.status == .pending }

    var body: some View {
        // As each place finishes, its skeleton cross-fades into the tile (at once under Reduce Motion).
        ZStack(alignment: .topLeading) {
            if isPending {
                skeleton.transition(.opacity)
            } else {
                content.transition(.opacity)
            }
        }
        .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.reveal, reduceMotion: reduceMotion), value: isPending)
    }

    /// Scanned in full and nothing there: the size is quieter, so the tiles that matter stand out.
    private var isEmptyPlace: Bool { tile.status == .scanned && tile.bytes == 0 && !tile.isLowerBound }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous)
    }

    /// The tile's layout, shared by the loaded tile and its skeleton.
    private var layout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                leading
                Text(tile.title)
                    .font(DustlingTheme.Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .skeletonText()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            size
            MiniMosaicView(
                mosaic: isPending ? Self.placeholderCells : tile.cells, color: MosaicView.color(for: tile.id),
                nibbling: tile.status == .moved)
                .skeletonBlock()
            Text(isPending ? Self.placeholderNote : tile.note)
                .font(DustlingTheme.Typography.caption)
                .foregroundStyle(tile.status == .locked || tile.status == .unreadable ? Palette.warning : Palette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .skeletonText()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var content: some View {
        layout
        .background(tile.isOutlined ? Palette.ground : Palette.panel, in: shape)
        .overlay { if tile.isOutlined { shape.strokeBorder(Palette.line, lineWidth: 1) } }
        // One element: the name, then the size and state ("4.2 GB, selected"), the note as the hint.
        // A tile that can be ticked is a toggle whose default action ticks it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.title)
        .accessibilityValue(tile.accessibilityValue)
        .accessibilityHint(tile.note)
        .accessibilityAddTraits(tile.status == .scanned && tile.canToggle ? .isToggle : [])
        .accessibilityAction {
            if tile.status == .scanned && tile.canToggle { models.junk.toggle(tile.id) }
        }
    }

    // MARK: Leading control

    @ViewBuilder private var leading: some View {
        switch tile.status {
        case .scanned where tile.canToggle:
            Toggle(isOn: Binding(get: { tile.isSelected }, set: { _ in models.junk.toggle(tile.id) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(Palette.accentFill)
                .accessibilityLabel(tile.title)
        case .scanned, .stopped, .notScannedYet:
            Toggle(isOn: .constant(tile.isSelected)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
        case .locked, .unreadable:
            PixelIconView(.lock, color: Palette.muted)
        case .queued:
            Toggle(isOn: .constant(true)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
        case .moving:
            BusyIndicator(label: "Moving…")
        case .moved, .cleaned:
            CheckMark()
        case .putBack:
            PixelIconView(.undo, color: Palette.success)
                .accessibilityLabel("Put back")
        case .pending:
            // The skeleton's checkbox block, the size of the real one.
            Toggle(isOn: .constant(false)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .skeletonBlock()
        }
    }

    // MARK: Size

    @ViewBuilder private var size: some View {
        if isPending {
            sizeText("00.00 GB").skeletonText()
        } else if let bytes = tile.bytes {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                sizeText(Bytes.format(bytes))
                if tile.isLowerBound {
                    Text("or more")
                        .font(DustlingTheme.Typography.caption)
                        .foregroundStyle(Palette.muted)
                }
            }
        } else {
            // No size is known: say so rather than show 0 bytes.
            Text("Size unknown")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                .foregroundStyle(Palette.muted)
                .frame(height: 22, alignment: .leading)
        }
    }

    private func sizeText(_ text: String) -> some View {
        Text(text)
            .font(.custom(DustlingTheme.Typography.pixelFamily, size: 18))
            .foregroundStyle(isEmptyPlace ? Palette.muted : Palette.ink)
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
    }

    // MARK: Skeleton

    /// What a scanned tile usually shows: two rows of cells and a one-line note.
    private static let placeholderCells = MiniMosaic(count: 2 * MiniMosaicView.columns, kind: .selected)
    private static let placeholderNote = Placeholder.text(0, base: 24, spread: 0)

    /// The tile's own layout in placeholder mode, outlined on `ground` so the `panel` blocks show.
    /// The stagger follows the tile's place in the catalog.
    private var skeleton: some View {
        layout
            .background(Palette.ground, in: shape)
            .overlay { shape.strokeBorder(Palette.line, lineWidth: 1) }
            .skeleton(
                true, index: JunkCategoryID.allCases.firstIndex(of: tile.id) ?? 0,
                accessibilityLabel: "\(tile.title): scanning")
    }
}

/// The success check that pops in (0.32 s spring; instant under Reduce Motion).
struct CheckMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        PixelIconView(.check, color: DustlingTheme.Palette.success)
            .scaleEffect(shown || reduceMotion ? 1 : 0.4)
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear {
                withAnimation(DustlingTheme.Motion.animation(DustlingTheme.Motion.checkPop, reduceMotion: reduceMotion)) {
                    shown = true
                }
            }
            .accessibilityLabel("Done")
    }
}

/// A tile's cells: 20 columns, 1 pt gaps, square cells, row by row (the mockups' `.tile2 .mosaic`).
struct MiniMosaicView: View {
    let mosaic: MiniMosaic
    let color: Color
    /// The cells shrink and fade away (the nibble), 7 ms apart; at once under Reduce Motion.
    var nibbling = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var nibbleStart: Date?
    @State private var nibbleFinished = false

    static let columns = 20
    private static let gap: CGFloat = 1

    private var cell: CGFloat {
        max(1, ((width - Self.gap * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)).rounded(.down))
    }

    var body: some View {
        let rows = max(1, (mosaic.count + Self.columns - 1) / Self.columns)
        let height = CGFloat(rows) * (cell + Self.gap) - Self.gap
        TimelineView(.animation(paused: reduceMotion || !nibbling || nibbleFinished)) { context in
            let elapsed = nibbleStart.map { context.date.timeIntervalSince($0) } ?? 0
            Canvas { canvas, _ in draw(&canvas, elapsed: elapsed) }
        }
        .frame(height: mosaic.count == 0 ? 0 : max(0, height))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in width = new }
            }
        }
        .task(id: nibbling) {
            nibbleFinished = false
            nibbleStart = nibbling ? .now : nil
            guard nibbling else { return }
            try? await Task.sleep(for: .seconds(Nibble.totalDuration(cells: mosaic.count, reduceMotion: reduceMotion)))
            if !Task.isCancelled { nibbleFinished = true }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ canvas: inout GraphicsContext, elapsed: Double) {
        let pitch = cell + Self.gap
        for index in 0..<mosaic.count {
            var rect = CGRect(
                x: CGFloat(index % Self.columns) * pitch, y: CGFloat(index / Self.columns) * pitch,
                width: cell, height: cell)
            var layer = canvas
            if nibbling {
                let state = Nibble.cell(order: index, elapsed: elapsed, reduceMotion: reduceMotion)
                guard state.opacity > 0 else { continue }
                let inset = cell * (1 - state.scale) / 2
                rect = rect.insetBy(dx: inset, dy: inset)
                layer.opacity = state.opacity
            }
            switch mosaic.kind {
            case .selected:
                layer.fill(Path(rect), with: .color(color))
            case .unselected:
                MosaicView.fillUnselected(rect, color: color, in: &layer)
            case .inTrash:
                // The mockups' `.tr`: category-colour stripes at 70%.
                MosaicView.hatch(rect, stripes: color.opacity(0.7), ground: nil, in: &layer)
            case .locked:
                MosaicView.hatch(rect, stripes: DustlingTheme.Palette.line, ground: DustlingTheme.Palette.panel, in: &layer)
            }
        }
    }
}
