import DustlingAppModel
import DustlingCore
import SwiftUI

/// Draws a `MosaicLayout` with `Canvas` (DESIGN-mosaic §5): square cells with a 2 pt gap, filled
/// column by column. Category cells take their series colour; "in Trash" and locked cells are hatched
/// (Honesty: moving to the Trash frees nothing, and a place Dustling can't read is never 0 bytes).
///
/// - Hover link: hovering a cell sets `hovered` to the tool that reclaims it; while anything is
///   hovered, every other cell dims to 28%.
/// - Nibble: cells of `nibbling` categories shrink to 40% and fade, 7 ms apart, capped at 420 ms.
///   Under Reduce Motion they go at once.
struct MosaicView: View {
    let layout: MosaicLayout
    @Binding var hovered: HomeLink?
    var nibbling: Set<JunkCategoryID> = []
    /// Categories drawn as unselected: their colour mixed 22% into `panel` (DESIGN-mosaic §2).
    var unselected: Set<JunkCategoryID> = []
    let accessibilitySummary: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var nibbleStart: Date?
    @State private var nibbleFinished = false

    private typealias Palette = DustlingTheme.Palette

    /// "In Trash" stripes: `muted` at 55%, clearly darker than the locked cells' `line` stripes in
    /// light mode and brighter than them in dark mode, so the two hatches are easy to tell apart.
    static let inTrashStripes = Palette.muted.opacity(0.55)

    /// Cells never grow past this, so a small mosaic doesn't turn into giant tiles.
    static let maxCell: CGFloat = 14

    private struct Metrics {
        let cell: CGFloat
        let gap: CGFloat
        var pitch: CGFloat { cell + gap }
    }

    private func metrics(for width: CGFloat) -> Metrics {
        Self.metrics(columns: layout.columns, width: width)
    }

    private static func metrics(columns: Int, width: CGFloat) -> Metrics {
        let columns = max(1, columns)
        var gap = DustlingTheme.Metrics.mosaicGap
        var cell = ((width - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        if cell < 4 {
            // Very large mosaics: a 1 pt gap keeps the cells visible.
            gap = 1
            cell = max(1, ((width - CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
        }
        return Metrics(cell: min(cell, Self.maxCell), gap: gap)
    }

    /// The loading skeleton's column count: about 40 GB at a quarter gigabyte a cell, four rows.
    static let placeholderColumns = 40

    /// The size the mosaic takes at `width` with `rows` rows of `columns` columns. Cells stop growing
    /// at `maxCell`, so a small mosaic is narrower than `width`.
    static func size(rows: Int, columns: Int, width: CGFloat) -> CGSize {
        let metrics = metrics(columns: columns, width: width)
        return CGSize(
            width: max(0, CGFloat(max(1, columns)) * metrics.pitch - metrics.gap),
            height: max(0, CGFloat(rows) * metrics.pitch - metrics.gap))
    }

    var body: some View {
        let metrics = metrics(for: width)
        let height = Self.size(rows: layout.rows, columns: layout.columns, width: width).height
        let nibbleCells = nibbleOrder()
        TimelineView(.animation(paused: reduceMotion || nibbling.isEmpty || nibbleFinished)) { context in
            let elapsed = nibbleStart.map { context.date.timeIntervalSince($0) } ?? 0
            Canvas { canvas, _ in
                draw(in: &canvas, metrics: metrics, nibbleOrder: nibbleCells, elapsed: elapsed)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in width = new }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hovered = cell(at: location, metrics: metrics).flatMap(HomeLink.link(for:))
            case .ended: hovered = nil
            }
        }
        // The timeline runs only while cells are still going, then stops.
        .task(id: nibbling) {
            nibbleFinished = false
            nibbleStart = nibbling.isEmpty ? nil : .now
            guard !nibbling.isEmpty else { return }
            let duration = Nibble.totalDuration(cells: nibbleOrder().count, reduceMotion: reduceMotion)
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { nibbleFinished = true }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    /// The position of each nibbling cell among all nibbling cells, by cell index.
    private func nibbleOrder() -> [Int: Int] {
        guard !nibbling.isEmpty else { return [:] }
        var order: [Int: Int] = [:]
        for (index, kind) in layout.cells.enumerated() {
            if case .category(let id) = kind, nibbling.contains(id) { order[index] = order.count }
        }
        return order
    }

    private func cell(at point: CGPoint, metrics: Metrics) -> CellKind? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / metrics.pitch), row = Int(point.y / metrics.pitch)
        guard row < layout.rows, column < layout.columns else { return nil }
        let index = column * layout.rows + row
        return index < layout.cells.count ? layout.cells[index] : nil
    }

    private func draw(in canvas: inout GraphicsContext, metrics: Metrics, nibbleOrder: [Int: Int], elapsed: Double) {
        for (index, kind) in layout.cells.enumerated() {
            let column = index / layout.rows, row = index % layout.rows
            var rect = CGRect(
                x: CGFloat(column) * metrics.pitch, y: CGFloat(row) * metrics.pitch,
                width: metrics.cell, height: metrics.cell)
            var opacity = HomeLink.cellOpacity(kind, hovered: hovered)
            if let order = nibbleOrder[index] {
                let state = Nibble.cell(order: order, elapsed: elapsed, reduceMotion: reduceMotion)
                guard state.opacity > 0 else { continue }
                let inset = metrics.cell * (1 - state.scale) / 2
                rect = rect.insetBy(dx: inset, dy: inset)
                opacity *= state.opacity
            }
            var layer = canvas
            layer.opacity = opacity
            switch kind {
            case .category(let id) where unselected.contains(id):
                Self.fillUnselected(rect, color: Self.color(for: id), in: &layer)
            case .category(let id):
                layer.fill(Path(rect), with: .color(Self.color(for: id)))
            case .inTrash:
                Self.hatch(rect, stripes: Self.inTrashStripes, ground: nil, in: &layer)
            case .locked:
                Self.hatch(rect, stripes: Palette.line, ground: Palette.panel, in: &layer)
            case .free:
                layer.fill(Path(rect), with: .color(Palette.ground))
                layer.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Palette.line), lineWidth: 1)
            case .other:
                layer.fill(Path(rect), with: .color(Palette.neutralCell))
            }
        }
    }

    static func color(for id: JunkCategoryID) -> Color {
        guard let slot = CategorySeries.slot(for: id), let series = DustlingTheme.Series(rawValue: slot - 1) else {
            // The Trash is never a category colour (DESIGN-mosaic §2).
            return DustlingTheme.Palette.neutralCell
        }
        return series.color
    }

    /// An unselected cell: the category colour mixed 22% into `panel`.
    static func fillUnselected(_ rect: CGRect, color: Color, in context: inout GraphicsContext) {
        context.fill(Path(rect), with: .color(Palette.panel))
        context.fill(Path(rect), with: .color(color.opacity(0.22)))
    }

    /// Stripes 2 pt wide every 5 pt at 135° (the mockups' `.lk` and `.tr` cells).
    static func hatch(_ rect: CGRect, stripes color: Color, ground: Color?, in context: inout GraphicsContext) {
        if let ground { context.fill(Path(rect), with: .color(ground)) }
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
        layer.stroke(stripes, with: .color(color), lineWidth: 2)
    }
}

/// The mosaic's loading skeleton: one block the size the mosaic takes at this width, with the
/// mosaic's own cell metrics and rows (`MosaicView.placeholderColumns` columns), leading-aligned
/// like the mosaic.
struct MosaicSkeleton: View {
    var index = 0
    @State private var width: CGFloat = 0

    var body: some View {
        let size = MosaicView.size(rows: MosaicLayout.rowCount, columns: MosaicView.placeholderColumns, width: width)
        SkeletonBlock(width: size.width, height: size.height, cornerRadius: SkeletonMetrics.textRadius, index: index)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}
