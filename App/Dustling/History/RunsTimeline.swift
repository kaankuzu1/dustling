import DustlingAppModel
import SwiftUI

/// The Runs tab (R03 "Timeline" with R01 run rows): newest first, one dot and time per run, and a
/// dashed line under the last Empty Trash: "Older runs can't be restored."
struct RunsTimeline: View {
    let entries: [HistoryScreen.TimelineEntry]
    let selectedRunID: UUID?
    let isRestoring: Bool
    let onSelect: (UUID) -> Void
    let onShowLog: (UUID) -> Void
    let onRestore: (UUID) -> Void
    let onShowInTrash: () -> Void
    /// The loading skeleton: `entries` are placeholders and every run draws in placeholder mode.
    var isPlaceholder = false

    private typealias Palette = DustlingTheme.Palette

    /// A run's dot-and-time line, the gap and the 54 pt row: the skeleton counts runs by it.
    static let groupHeight: CGFloat = 80
    static let groupSpacing: CGFloat = 14
    static let verticalPadding: CGFloat = 14

    /// The tab's loading skeleton: as many placeholder runs as fit in `height`.
    static func placeholder(height: CGFloat) -> RunsTimeline {
        let count = SkeletonMetrics.rowCount(
            height: height - 2 * verticalPadding, rowHeight: groupHeight, spacing: groupSpacing)
        return RunsTimeline(
            entries: (0..<count).map { .run(.placeholder($0)) }, selectedRunID: nil, isRestoring: false,
            onSelect: { _ in }, onShowLog: { _ in }, onRestore: { _ in }, onShowInTrash: {}, isPlaceholder: true)
    }

    var body: some View {
        ScrollViewReader { proxy in ScrollView {
            LazyVStack(alignment: .leading, spacing: Self.groupSpacing) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    switch entry {
                    case .run(let line):
                        RunGroup(
                            line: line, isSelected: line.id == selectedRunID, isRestoring: isRestoring,
                            onSelect: { onSelect(line.id) }, onShowLog: { onShowLog(line.id) },
                            onRestore: { onRestore(line.id) }, onShowInTrash: onShowInTrash)
                        .skeleton(isPlaceholder, index: index)
                        .id(line.id)
                    case .trashEmptied(let text):
                        TrashEmptiedLine(text: text)
                    }
                }
            }
            .padding(.horizontal, DustlingTheme.Metrics.gutter)
            .padding(.vertical, Self.verticalPadding)
        }
        .scrollDisabled(isPlaceholder)
        // Placeholder runs can't be focused or stepped through.
        .arrowKeyList(
            isPlaceholder ? [] : runIDs, current: selectedRunID, proxy: proxy, isEnabled: !isPlaceholder,
            select: onSelect)
        }
    }

    private var runIDs: [UUID] {
        entries.compactMap { if case .run(let line) = $0 { line.id } else { nil } }
    }
}

/// The colour each tool's icon and dot use in the approved mockups (`--c` per run).
extension HistoryScreen.Tool {
    var color: Color {
        switch self {
        case .junkScan: return DustlingTheme.Series.c1.color
        case .uninstaller: return DustlingTheme.Series.c4.color
        case .startupItems: return DustlingTheme.Series.c5.color
        case .emptyTrash: return DustlingTheme.Palette.muted
        }
    }
}

/// `.tl-g`: the dot and time, then the run row, on a 2 pt line at the left.
private struct RunGroup: View {
    let line: HistoryScreen.RunLine
    let isSelected: Bool
    let isRestoring: Bool
    let onSelect: () -> Void
    let onShowLog: () -> Void
    let onRestore: () -> Void
    let onShowInTrash: () -> Void

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(line.dimmed ? Palette.line : line.tool.color)
                    .frame(width: 12, height: 12)
                    .skeletonBlock(cornerRadius: 6)
                    .overlay(Circle().strokeBorder(Palette.ground, lineWidth: 3).padding(-3))
                Text(line.when)
                    .font(DustlingTheme.Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                    .accessibilityAddTraits(.isHeader)
                    .skeletonText()
            }
            .padding(.leading, 1)
            RunRowView(
                line: line, isSelected: isSelected, isRestoring: isRestoring, onRestore: onRestore,
                onShowInTrash: onShowInTrash)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onShowLog)
                .onTapGesture(perform: onSelect)
                .contextMenu { Button("Show log", action: onShowLog) }
                .accessibilityAction(named: "Select", onSelect)
                .accessibilityAction(named: "Show log", onShowLog)
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Palette.line).frame(width: 2).padding(.leading, 6).accessibilityHidden(true)
                }
        }
    }
}

/// `runRow()`: tool icon, tool and what it touched, time with item and skipped counts, the chip,
/// the size and Restore (or Show in Trash without Full Disk Access).
struct RunRowView: View {
    let line: HistoryScreen.RunLine
    let isSelected: Bool
    let isRestoring: Bool
    let onRestore: () -> Void
    let onShowInTrash: () -> Void

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 12) {
            ToolIcon(tool: line.tool)
                .skeletonBlock(cornerRadius: DustlingTheme.Metrics.controlRadius)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title)
                    .font(DustlingTheme.Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .skeletonText()
                Text(line.caption)
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .skeletonText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let chip = line.chip { RunChip(chip: chip) }
            Text(line.size ?? "")
                .font(DustlingTheme.Typography.size)
                .foregroundStyle(Palette.ink)
                .skeletonText()
                .frame(width: 84, alignment: .trailing)
            Group {
                switch line.action {
                case .restore:
                    Button(action: onRestore) {
                        HStack(spacing: 5) {
                            PixelIconView(.undo, color: Palette.ink)
                            Text("Restore")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isRestoring)
                case .showInTrash:
                    Button("Show in Trash", action: onShowInTrash)
                        .controlSize(.small)
                        .help(CleanupGate.limitedNote)
                case nil:
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: 108, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
        .opacity(line.dimmed ? 0.6 : 1)
        .background(
            isSelected ? Palette.rowSelection : Color.clear,
            in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A 30 pt tile of the tool's colour at 17% over `ground`, the icon at the full colour. Empty Trash
/// uses the system trash icon in neutral colours.
struct ToolIcon: View {
    let tool: HistoryScreen.Tool
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
            .fill(Palette.ground)
            .overlay(
                RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
                    .fill(tool == .emptyTrash ? Palette.panel : tool.color.opacity(0.17)))
            .frame(width: DustlingTheme.Metrics.iconTile, height: DustlingTheme.Metrics.iconTile)
            .overlay {
                switch tool {
                case .junkScan: PixelIconView(.broom, color: tool.color)
                case .uninstaller: PixelIconView(PixelIcon.apps, color: tool.color)
                case .startupItems: PixelIconView(PixelIcon.power, color: tool.color)
                case .emptyTrash:
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(Palette.ink2)
                }
            }
            .accessibilityHidden(true)
    }
}

struct RunChip: View {
    let chip: HistoryScreen.Chip

    var body: some View {
        switch chip.tone {
        case .success:
            Chip(text: chip.text, kind: .success, icon: chip == .canBeRestored ? .undo : .check)
        case .warning:
            Chip(text: chip.text, kind: .warning, icon: .warn)
        case .neutral:
            Chip(text: chip.text)
        }
    }
}

/// `.tl-cut`: "Trash emptied on 5 Nov. Older runs can't be restored." between two dashed rules.
private struct TrashEmptiedLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            dash
            Text(text)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                .foregroundStyle(DustlingTheme.Palette.muted)
                .layoutPriority(1)
            dash
        }
        .padding(.vertical, 2)
    }

    private var dash: some View {
        Line()
            .stroke(DustlingTheme.Palette.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .frame(height: 1.5)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
