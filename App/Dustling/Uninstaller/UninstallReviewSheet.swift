import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// Review all files: every file of the selected apps, grouped by app (the app first, then its
/// leftovers), in the style of Junk scan's Review files. Unticking a file leaves it where it is;
/// unticking the app deselects it. Files that can't move show why. Done keeps the changes; Cancel
/// drops them.
struct UninstallReviewSheet: View {
    @Environment(AppModels.self) private var models
    @Environment(\.dismiss) private var dismiss
    /// The list as it was when the sheet opened; rows and order stay put while the user ticks.
    @State private var base: UninstallReview?
    /// The draft of files left out; applied only on Done.
    @State private var excluded: Set<URL> = []

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let totals = base?.totals(excluding: excluded)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review all files")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 15).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Untick a file to leave it where it is. Untick an app to keep it. Nothing moves until you choose Move to Trash.")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Hairline()
            if let base, let totals {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(base.sections) { section in
                            Section {
                                ForEach(section.rows) { row in
                                    ReviewRow(row: row, home: models.homeDirectory, excluded: $excluded,
                                              appExcluded: excluded.contains(section.id) && !row.isApp)
                                }
                            } header: {
                                sectionHeader(section, bytes: totals.sections[section.id] ?? 0)
                            }
                        }
                    }
                }
            } else {
                Spacer()
            }
            Hairline()
            HStack(spacing: 8) {
                Text(totals.map { UninstallReview.footerLine(count: $0.count, bytes: $0.bytes) } ?? "")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13.5).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    models.uninstaller.applyReview(excluding: excluded)
                    dismiss()
                }
                .dustlingPrimary()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: DustlingTheme.Metrics.actionBarHeight)
        }
        .frame(width: 760, height: 560)
        .background(Palette.ground)
        .task {
            excluded = models.uninstaller.reviewExclusions
            base = models.uninstaller.review()
        }
    }

    private func sectionHeader(_ section: UninstallReview.Section, bytes: UInt64) -> some View {
        HStack(spacing: 8) {
            AppIconView(app: section.app, size: 20)
            Text(section.app.displayName)
                .font(DustlingTheme.Typography.rowTitle)
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            Text(Bytes.format(bytes))
                .font(DustlingTheme.Typography.size)
                .foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Palette.panel)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ReviewRow: View {
    let row: UninstallReview.Row
    let home: URL
    @Binding var excluded: Set<URL>
    /// Its app is unticked, so nothing of it moves.
    let appExcluded: Bool

    private typealias Palette = DustlingTheme.Palette

    /// Read from the draft here, so a tick redraws only this row.
    private var isIncluded: Bool { row.disabledReason == nil && !excluded.contains(row.url) && !appExcluded }

    var body: some View {
        HStack(spacing: DustlingTheme.Metrics.columnGap) {
            Toggle(isOn: Binding(
                get: { isIncluded },
                set: { on in if on { excluded.remove(row.url) } else { excluded.insert(row.url) } }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(row.disabledReason != nil || appExcluded)
                .accessibilityLabel(row.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(DustlingTheme.Typography.body)
                        .foregroundStyle(row.disabledReason == nil ? Palette.ink : Palette.muted)
                    ForEach(Array(row.badges.enumerated()), id: \.offset) { _, badge in
                        let shown = UninstallerScreen.badge(badge)
                        Chip(text: shown.text, kind: shown.style == .warning ? .warning : shown.style == .admin ? .admin : .neutral)
                    }
                }
                Text(UninstallerScreen.path(row.url, home: home))
                    .font(DustlingTheme.Typography.path)
                    .foregroundStyle(Palette.muted)
                    .truncationMode(.middle)
                if let reason = row.disabledReason {
                    Text(reason)
                        .font(DustlingTheme.Typography.caption)
                        .foregroundStyle(Palette.warning)
                } else if row.isApp && excluded.contains(row.url) {
                    Text("This app stays, with all its files")
                        .font(DustlingTheme.Typography.caption)
                        .foregroundStyle(Palette.muted)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.isApp && row.bytes == 0 ? "Link" : Bytes.format(row.bytes))
                .font(DustlingTheme.Typography.size)
                .foregroundStyle(isIncluded ? Palette.ink : Palette.muted)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(minHeight: DustlingTheme.Metrics.rowMinHeight)
        .accessibilityElement(children: .contain)
    }
}
