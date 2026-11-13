import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// The Log tab (R07 "Readable log"): every attempted path of the selected run and what happened,
/// with filter chips (All, Moved, Skipped, Failed), **Show log file in Finder** and **Copy for a bug
/// report** (the run's own log lines).
struct LogTab: View {
    @Environment(AppModels.self) private var models
    /// nil while History is still being read: the tab draws as its loading skeleton.
    let run: RunRow?
    let runs: [RunRow]
    let context: HistoryScreen.Context
    let onSelectRun: (UUID) -> Void
    @State private var filter: HistoryScreen.LogFilter = .all
    @State private var copied = false

    private typealias Palette = DustlingTheme.Palette

    /// A log line: 11.5 pt Geist Mono with 3 pt above and below. The skeleton counts lines by it.
    private static let lineHeight: CGFloat = 21
    /// The log panel's height, for how many skeleton lines fill it.
    @State private var panelHeight: CGFloat = 0
    /// What the skeleton's title and filter stand in for.
    private static let placeholderRecord = RunRecord(startedAt: .now, kind: .junkClean, entries: [], restorable: false)

    var body: some View {
        let isPlaceholder = run == nil
        let record = run?.record ?? Self.placeholderRecord
        let rows = isPlaceholder
            ? (0..<SkeletonMetrics.rowCount(height: panelHeight - 16, rowHeight: Self.lineHeight))
                .map { HistoryScreen.LogRow.placeholder($0) }
            : HistoryScreen.logRows(record, context).filter { filter.includes($0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(runs) { other in
                        Button(HistoryScreen.logTitle(other.record, context)) { onSelectRun(other.id) }
                    }
                } label: {
                    Text(HistoryScreen.logTitle(record, context))
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 14).weight(.semibold))
                        .foregroundStyle(Palette.ink)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose another run")
                .skeletonBlock()
                .skeleton(isPlaceholder)
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(HistoryScreen.logFilters(record, context), id: \.filter) { chip in
                        Text(chip.label).tag(chip.filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .skeletonBlock(cornerRadius: DustlingTheme.Metrics.controlRadius)
                .skeleton(isPlaceholder, index: 1)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text(record.entries.isEmpty ? "This run recorded no items." : "No lines match.")
                            .foregroundStyle(Palette.muted)
                            .padding(.vertical, 3)
                    }
                    ForEach(rows) { row in
                        LogLineView(row: row)
                            .skeleton(isPlaceholder, index: row.id + 2)
                    }
                }
                .font(.custom(DustlingTheme.Typography.monoFamily, size: 11.5))
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollDisabled(isPlaceholder)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { panelHeight = $0 }
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
            .skeletonSurfaceIsPanel()
            HStack(spacing: 8) {
                Button {
                    if let run { models.showLogInFinder(models.history.logFile(for: run.id)) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").accessibilityHidden(true)
                        Text("Show log file in Finder")
                    }
                }
                Button(copied ? "Copied" : "Copy for a bug report") { copy() }
                    .help("Copies this run's lines from the log, with your home folder shown as ~")
            }
            .disabled(isPlaceholder)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, DustlingTheme.Metrics.gutter)
        .padding(.top, 14)
        .onChange(of: run?.id) { filter = .all; copied = false }
    }

    private func copy() {
        guard let id = run?.id else { return }
        Task {
            let text = await models.history.bugReport(for: id)
            let board = NSPasteboard.general
            board.clearContents()
            copied = board.setString(text, forType: .string)
        }
    }
}

/// `.logl`: the result (done in green, skipped and failed in amber), the path and a note.
private struct LogLineView: View {
    let row: HistoryScreen.LogRow
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.result)
                .fontWeight(.medium)
                .foregroundStyle(row.tone == .done ? Palette.success : Palette.warning)
                .skeletonText()
                // Fits the longest result, "needs password".
                .frame(width: 110, alignment: .leading)
            Text(row.path)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .skeletonText()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.note)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .skeletonText()
        }
        .padding(.vertical, 3)
        // Spelled out: combining the selectable text left the line without anything for VoiceOver to read.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.result), \(row.path), \(row.note)")
    }
}
