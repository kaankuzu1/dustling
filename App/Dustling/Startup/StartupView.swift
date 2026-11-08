import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// Startup items (SCREENS-final §5, merged from S01 and S03): one table in three groups with "N of M
/// on" headers, the filter in the toolbar, the orphan banner on top, and switches. Turning off is the
/// main, reversible action; Remove is secondary and always confirms. Items macOS only lets System
/// Settings change link there, and anything that needs the helper is shown but disabled.
struct StartupView: View {
    @Environment(AppModels.self) private var models
    /// The item the Remove confirmation is about. Dropped once it is answered.
    @State private var removing: StartupRow?
    /// The list's height, for how many skeleton rows fill it.
    @State private var listHeight: CGFloat = 0

    private typealias Palette = DustlingTheme.Palette

    static let loginItemsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    var body: some View {
        @Bindable var startup = models.startup
        VStack(spacing: 0) {
            ScreenToolbar(
                title: "Startup items",
                subtitle: StartupScreen.subtitle(startup.items, isLoading: startup.isLoading)
            ) {
                Picker("Show", selection: $startup.kindFilter) {
                    ForEach(StartupScreen.segments(startup.items), id: \.filter) { segment in
                        Text(segment.label).tag(segment.filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show one kind of startup item")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    banners
                    if startup.items.isEmpty && startup.isLoading {
                        skeleton
                    } else {
                        ForEach(startup.shownGroups) { group in
                            StartupGroupSection(
                                group: group, busyItemID: startup.busyItemID,
                                canRemove: { startup.canRemove($0) },
                                onToggle: { item in Task { await startup.toggle(item) } },
                                onRemove: { removing = $0 })
                        }
                    }
                }
                .padding(.horizontal, DustlingTheme.Metrics.gutter)
                .padding(.vertical, 14)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
            ActionBar(
                title: "Turning an item off is reversible",
                caption: "Changes apply right away. Removing an item asks first."
            ) {
                Button("Open Login Items settings") { NSWorkspace.shared.open(Self.loginItemsSettings) }
            }
        }
        .background(Palette.ground)
        .task(id: models.fullDiskAccessKey) { models.reloadStartup() }
        #if DEBUG
        .task {
            if StartupHistoryFixture.opensRemoveSheet {
                removing = models.startup.groups.flatMap(\.rows).first(where: \.isOrphaned)
            }
        }
        #endif
        .dismissedOnQuit($removing)
        .sheet(item: $removing) { row in
            RemoveStartupItemSheet(row: row, canTakeOutOfTrash: startup.canTakeOutOfTrash) { confirmedLimited in
                Task { await startup.remove(row.item, confirmedLimited: confirmedLimited) }
            }
        }
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        let startup = models.startup
        if let refusal = startup.refusal {
            Banner(title: "Nothing was removed.", message: refusal, leading: .icon(.warn))
        }
        if let change = startup.lastResult {
            ChangeResultBanner(change: change, canTakeOutOfTrash: startup.canTakeOutOfTrash)
        }
        if let text = startup.orphanScreenBanner, let orphans = startup.orphanBanner?.items {
            OrphanBannerView(
                text: text,
                onTurnOff: {
                    Task {
                        for item in orphans where item.isEnabled && startup.canRemove(item) {
                            await startup.toggle(item)
                        }
                    }
                },
                onRemove: {
                    // One at a time, each confirmed: the first one that can go.
                    if let item = orphans.first(where: { startup.canRemove($0) }) {
                        removing = startup.groups.flatMap(\.rows).first { $0.id == item.id }
                    }
                })
                .disabled(startup.busyItemID != nil)
        }
        if !startup.issues.isEmpty {
            Banner(
                title: "Some startup items couldn't be read.",
                message: StartupScreen.issueSummary(startup.issues, home: models.homePath),
                leading: .icon(.warn))
        }
    }

    /// A group as it will appear: its header, then rows, all in placeholder mode.
    private var skeleton: some View {
        let header = StartupGroupHeader(
            title: StartupScreen.heading(.agents), caption: StartupScreen.caption(.agents),
            onCount: "0 of 0 on")
        // The list's height less its vertical padding (14 + 14) and the group header (about 28).
        let rows = SkeletonMetrics.rowCount(height: listHeight - 56, rowHeight: StartupRowView.minHeight)
        return VStack(alignment: .leading, spacing: 0) {
            header.skeleton(true)
            ForEach(0..<rows, id: \.self) { StartupRowView.placeholder($0 + 1) }
        }
    }
}

/// One group: its header with the on count, then the rows.
private struct StartupGroupSection: View {
    let group: StartupGroup
    let busyItemID: String?
    let canRemove: (StartupItem) -> Bool
    let onToggle: (StartupItem) -> Void
    let onRemove: (StartupRow) -> Void

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StartupGroupHeader(
                title: StartupScreen.heading(group.kind), caption: StartupScreen.caption(group.kind),
                onCount: group.kind == .loginItems ? nil : StartupScreen.onCount(on: group.onCount, total: group.total))
            if group.kind == .loginItems {
                LoginItemsRow()
            } else if group.rows.isEmpty {
                Text(group.total == 0 ? "None on this Mac" : "None match")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 10)
                    .frame(height: 42, alignment: .leading)
                    .overlay(alignment: .bottom) { Hairline() }
            } else {
                ForEach(group.rows) { row in
                    StartupRowView(
                        row: row, isBusy: busyItemID == row.id, isLocked: busyItemID != nil,
                        canRemove: canRemove(row.item), onToggle: { onToggle(row.item) },
                        onRemove: { onRemove(row) })
                }
                if group.rows.contains(where: { $0.badge == .helper }) {
                    Text("Items marked Helper need the cleanup helper (coming in a later version), so they can't be changed yet.")
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                }
            }
        }
    }
}

/// A group's header: its name, a muted caption and the "N of M on" count. Shared with the skeleton.
private struct StartupGroupHeader: View {
    let title: String
    let caption: String
    let onCount: String?

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(DustlingTheme.Typography.rowTitle)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .skeletonText()
            Text(caption)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                .foregroundStyle(Palette.muted)
                .skeletonText()
            Spacer(minLength: 8)
            if let onCount {
                Text(onCount)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
                    .skeletonText()
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// Login items can't be listed: macOS has no API for other apps' login items. The row says so and
/// links to System Settings instead of pretending.
private struct LoginItemsRow: View {
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 10) {
            PixelIconView(.arrow, color: Palette.accent)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("Apps that open when you log in")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text("macOS doesn't let other apps list or change these, so Dustling links to them instead.")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.open(StartupView.loginItemsSettings)
            } label: {
                Chip(text: StartupScreen.Badge.inSystemSettings.text)
            }
            .buttonStyle(.plain)
            .help("Opens Login Items in System Settings")
            .accessibilityLabel("Open Login Items in System Settings")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// What the last switch or remove did. Never silent: a failure says why.
private struct ChangeResultBanner: View {
    @Environment(AppModels.self) private var models
    let change: StartupChange
    let canTakeOutOfTrash: Bool

    var body: some View {
        let result = change.result
        let movedToTrash = change.record.entries.contains { if case .movedToTrash = $0.outcome { true } else { false } }
        Banner(
            title: result.title,
            message: result.message ?? (movedToTrash
                ? (canTakeOutOfTrash ? "You can put it back from History until you empty the Trash."
                                     : CleanupGate.limitedNote)
                : "Switch it back any time."),
            tone: result.success ? .success : .warning,
            leading: .icon(result.success ? .check : .warn)
        ) {
            if movedToTrash {
                if canTakeOutOfTrash {
                    Button("View in History") { models.selection = .history }
                } else {
                    Button("Show in Trash") { models.showTrashInFinder() }
                }
            }
            Button("OK") { models.startup.dismissResult() }
        }
    }
}
