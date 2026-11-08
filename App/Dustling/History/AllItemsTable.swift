import DustlingAppModel
import DustlingCore
import SwiftUI

/// The All items tab (R04): a searchable table of every item Dustling recorded, with a Restorable /
/// All filter. Columns: original location (Geist Mono), run, size, status. Checkboxes pick single
/// items to put back; only items still in the Trash can be checked.
struct AllItemsTable: View {
    @Environment(AppModels.self) private var models
    let context: HistoryScreen.Context
    @Binding var checked: Set<String>
    /// The table's height, for how many skeleton rows fill it.
    @State private var tableHeight: CGFloat = 0

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        @Bindable var history = models.history
        let items = history.filteredItems
        // Still reading: the table's own rows with placeholder items, and nothing to search yet.
        let isLoading = history.isLoading && history.runs.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    PixelIconView(.search, color: Palette.muted)
                    TextField("Search moved items", text: $history.search)
                        .textFieldStyle(.plain)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                }
                .padding(.horizontal, 9)
                .frame(width: 280, height: 28)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1))
                Picker("Show", selection: $history.itemFilter) {
                    Text("Restorable").tag(HistoryItemFilter.restorable)
                    Text("All").tag(HistoryItemFilter.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(isLoading ? "000 items" : "\(items.count.formatted()) \(items.count == 1 ? "item" : "items")")
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
                    .skeletonText()
                    .skeleton(isLoading)
            }
            .disabled(isLoading)
            header
            if isLoading {
                let rows = SkeletonMetrics.rowCount(height: tableHeight, rowHeight: ItemRow.height)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<rows, id: \.self) { index in
                            ItemRow(item: .placeholder(index), context: context, isChecked: false, canCheck: false) {}
                                .skeleton(true, index: index)
                        }
                    }
                }
                .scrollDisabled(true)
                .frame(maxHeight: .infinity, alignment: .top)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { tableHeight = $0 }
            } else if items.isEmpty {
                Text(history.search.isEmpty
                     ? (history.itemFilter == .restorable ? "Nothing can be put back right now." : "No items yet.")
                     : "No items match.")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(10)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            ItemRow(item: item, context: context, isChecked: checked.contains(item.id),
                                    canCheck: item.restorable && history.canTakeOutOfTrash && !history.isRestoring) {
                                if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, DustlingTheme.Metrics.gutter)
        .padding(.top, 14)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 18, height: 1)
            Text("Original location").frame(maxWidth: .infinity, alignment: .leading)
            Text("Run").frame(width: 170, alignment: .leading)
            Text("Size").frame(width: 80, alignment: .trailing)
            Text("Status").frame(width: 170, alignment: .leading)
        }
        .font(.custom(DustlingTheme.Typography.sansFamily, size: 11.5).weight(.medium))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct ItemRow: View {
    let item: HistoryItem
    let context: HistoryScreen.Context
    let isChecked: Bool
    let canCheck: Bool
    let onToggle: () -> Void

    private typealias Palette = DustlingTheme.Palette

    static let height: CGFloat = 38

    var body: some View {
        let status = HistoryScreen.itemStatus(
            item.entry, kind: item.runKind, runDate: item.runDate, restorable: item.restorable, context)
        HStack(spacing: 12) {
            Toggle("Put back \(item.name)", isOn: Binding(get: { isChecked }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canCheck)
                .skeletonBlock()
                .frame(width: 18)
            Text(HistoryScreen.displayPath(item.path, home: context.home))
                .font(DustlingTheme.Typography.path)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .skeletonText()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.path)
            Text(HistoryScreen.runColumn(item.runKind, item.runDate, context))
                .lineLimit(1)
                .skeletonText()
                .frame(width: 170, alignment: .leading)
            Text(item.bytes > 0 ? Bytes.format(item.bytes) : "")
                .monospacedDigit()
                .skeletonText()
                .frame(width: 80, alignment: .trailing)
            Group {
                switch status.tone {
                case .success: Chip(text: status.text, kind: .success, icon: .check)
                case .warning: Chip(text: status.text, kind: .warning)
                case .neutral: Chip(text: status.text)
                }
            }
            .skeletonBlock(cornerRadius: DustlingTheme.Metrics.chipHeight / 2)
            .frame(width: 170, alignment: .leading)
            .help(status.text)
        }
        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }
}
