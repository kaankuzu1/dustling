import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// Review files: every file the cleanup would move, grouped by category in tile order. Unticking a
/// file leaves it where it is. Files that can't move (in use, needs the helper, locked) are shown
/// disabled with their reason and never count. Done keeps the changes; Cancel drops them.
struct ReviewFilesSheet: View {
    @Environment(AppModels.self) private var models
    @Environment(\.dismiss) private var dismiss
    /// The list as it was when the sheet opened; rows and order stay put while the user ticks.
    @State private var base: FileReview?
    /// The draft of files left out; kept only on Done.
    @State private var excluded: Set<URL> = []

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let review = base?.applying(excluding: excluded)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review files")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 15).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Untick a file to leave it where it is. Nothing moves until you choose Move to Trash.")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Hairline()
            if let review {
                FileList(review: review, home: models.homeDirectory, excluded: $excluded)
            } else {
                Spacer()
            }
            Hairline()
            HStack(spacing: 8) {
                Text(review?.footerLine ?? "")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13.5).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    models.junk.setExclusions(excluded)
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
            excluded = models.junk.excludedItems
            base = models.junk.review(
                excluding: [], skipping: models.cleanupSkip, appName: { AppModels.appName(bundleID: $0) })
        }
    }
}

/// The rows, lazily, with each category's header pinned while its files scroll.
private struct FileList: View {
    let review: FileReview
    let home: URL
    @Binding var excluded: Set<URL>

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(review.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            FileRow(row: row, home: home, excluded: $excluded)
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Text(section.title)
                                .font(DustlingTheme.Typography.rowTitle)
                                .foregroundStyle(Palette.ink)
                            Spacer(minLength: 8)
                            Text(Bytes.format(section.selectedBytes))
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
            }
        }
    }
}

private struct FileRow: View {
    let row: FileReview.Row
    let home: URL
    @Binding var excluded: Set<URL>

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: DustlingTheme.Metrics.columnGap) {
            Toggle(isOn: Binding(
                get: { row.isIncluded },
                set: { on in if on { excluded.remove(row.url) } else { excluded.insert(row.url) } }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(row.disabledReason != nil)
                .accessibilityLabel(row.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(DustlingTheme.Typography.body)
                    .foregroundStyle(row.disabledReason == nil ? Palette.ink : Palette.muted)
                Text(JunkScreen.displayPath(row.url, home: home))
                    .font(DustlingTheme.Typography.path)
                    .foregroundStyle(Palette.muted)
                    .truncationMode(.middle)
                if let reason = row.disabledReason {
                    Text(reason)
                        .font(DustlingTheme.Typography.caption)
                        .foregroundStyle(Palette.warning)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Bytes.format(row.bytes))
                .font(DustlingTheme.Typography.size)
                .foregroundStyle(row.isIncluded ? Palette.ink : Palette.muted)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(minHeight: DustlingTheme.Metrics.rowMinHeight)
        .accessibilityElement(children: .contain)
    }
}
