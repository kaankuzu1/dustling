import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// The Uninstaller (SCREENS-final §4, U01 "List and leftovers"): apps on the left, the selected app's
/// leftovers on the right, the confirm sheet, then Removing app by app and a summary. It lists apps
/// only with Full Disk Access (looking for leftovers opens other apps' data).
struct UninstallerView: View {
    @Environment(AppModels.self) private var models
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var sort: UninstallerScreen.Sort = .size
    @State private var current: URL?
    /// The confirmation the sheet shows. Dropped as soon as it is used or cancelled.
    @State private var confirming: ConfirmModel?
    @State private var confirmingEmptyTrash = false
    @State private var reviewing = false
    /// The app list's height, for how many skeleton rows fill it.
    @State private var listHeight: CGFloat = 0

    private typealias Palette = DustlingTheme.Palette

    private enum Phase { case limited, list, removing, done }

    private var phase: Phase {
        let model = models.uninstaller
        if model.isUninstalling { return .removing }
        if model.result != nil { return .done }
        if !models.uninstallerAllowed && model.apps.isEmpty { return .limited }
        return .list
    }

    var body: some View {
        let shown = UninstallerScreen.arrange(models.uninstaller.apps, query: query, sort: sort)
        VStack(spacing: 0) {
            ScreenToolbar(title: "Uninstaller", subtitle: subtitle) { tools }
            if !models.uninstallerAllowed && models.hasProbedFullDiskAccess {
                limitedBanner
                    .padding(.horizontal, DustlingTheme.Metrics.gutter)
                    .padding(.top, 12)
            }
            if let refusal = models.uninstaller.refusal, phase == .list {
                // A refused uninstall is never silent.
                Banner(title: "Nothing was moved.", message: refusal, leading: .icon(.warn)) {
                    Button("OK") { models.uninstaller.clearRefusal() }
                }
                .padding(.horizontal, DustlingTheme.Metrics.gutter)
                .padding(.top, 12)
            }
            if phase == .limited {
                PickAnApp(text: "Needs Full Disk Access to look for leftovers")
            } else {
                HStack(spacing: 0) {
                    appList(shown)
                        .frame(width: 350)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(Palette.line).frame(width: 1).accessibilityHidden(true)
                        }
                    rightPane(shown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            actionBar
        }
        .background(Palette.ground)
        .task(id: models.fullDiskAccessKey) { models.loadUninstallerIfAllowed() }
        .dismissedOnQuit($confirming)
        .sheet(item: $confirming) { confirm in
            UninstallConfirmSheet(confirm: confirm) { start(confirm) }
        }
        .sheet(isPresented: $confirmingEmptyTrash) { EmptyTrashSheet() }
        .dismissedOnQuit($confirmingEmptyTrash)
        .sheet(isPresented: $reviewing) { UninstallReviewSheet() }
        .dismissedOnQuit($reviewing)
        #if DEBUG
        .task(id: models.uninstallerFixtureConfirm) {
            confirming = models.uninstallerFixtureConfirm ? models.uninstaller.confirmation : nil
        }
        .task(id: models.uninstallerFixtureReview) { reviewing = models.uninstallerFixtureReview }
        #endif
    }

    // MARK: Toolbar

    private var subtitle: String {
        let model = models.uninstaller
        switch phase {
        case .limited: return "Apps and the files they leave behind"
        case .removing:
            let count = model.progress?.apps.count ?? 0
            return "Removing \(count) \(count == 1 ? "app" : "apps")…"
        case .done: return "Uninstall finished"
        case .list:
            if model.isLoading && model.apps.isEmpty { return "Looking for apps…" }
            let total = model.apps.reduce(UInt64(0)) { $0 + $1.totalBytes }
            let count = model.apps.count
            return "\(count) \(count == 1 ? "app" : "apps"), \(Bytes.format(total)) with leftovers"
                + (model.isLoading ? ". Still counting" : "")
        }
    }

    @ViewBuilder private var tools: some View {
        HStack(spacing: 6) {
            PixelIconView(.search, color: Palette.muted)
            TextField("Search apps", text: $query)
                .textFieldStyle(.plain)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
        }
        .padding(.horizontal, 8)
        .frame(width: 200, height: 26)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous))
        .disabled(phase == .limited)
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(UninstallerScreen.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                PixelIconView(.sort, color: Palette.ink)
                Text(sort.title)
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(phase == .limited)
        .help("Sort the apps")
    }

    // MARK: Limited mode

    private var limitedBanner: some View {
        Banner(
            title: "Needs Full Disk Access to look for leftovers.",
            message: "Without it, macOS would ask before Dustling looks inside other apps' data, so the "
                + "Uninstaller waits until access is on.",
            leading: .worriedMote
        ) {
            Button("Grant access") { models.openOnboarding(at: .fullDiskAccess, using: openWindow) }
                .dustlingPrimary()
        }
    }

    // MARK: Left pane

    private func appList(_ shown: [AppRow]) -> some View {
        let model = models.uninstaller
        let progress = model.progress
        // Apps an uninstall removed leave the list; while it runs and on its summary they still show
        // their spinner or check.
        let removed = progress?.apps.filter { entry in !shown.contains { $0.id == entry.id } } ?? []
        return ScrollViewReader { proxy in ScrollView {
            LoadingSwap(isLoading: model.apps.isEmpty && model.isLoading) {
                let rows = SkeletonMetrics.rowCount(height: listHeight - 16, rowHeight: AppListRow.minHeight)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { AppListRow.placeholder($0) }
                }
            } content: {
            LazyVStack(spacing: 0) {
                if shown.isEmpty && removed.isEmpty {
                    Text(query.isEmpty ? "No apps found" : "No apps match \u{201C}\(query)\u{201D}")
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .padding(16)
                }
                ForEach(shown) { row in
                    AppListRow(
                        row: row, isCurrent: row.id == currentID(shown),
                        isSelected: model.selection.contains(row.id),
                        progress: progress?.apps.first { $0.id == row.id }?.state,
                        isLocked: model.isUninstalling || model.isRestoring,
                        onToggle: { on in
                            if on { model.selection.insert(row.id) } else { model.selection.remove(row.id) }
                        },
                        onSelect: { current = row.id })
                }
                // Their own IDs: the lazy stack otherwise kept showing the row the app had in the list
                // above (same URL), stuck on its spinner after the app finished.
                ForEach(removed, id: \.removedRowID) { entry in
                    AppListRow(
                        row: AppRow(app: entry.app, isCounting: false, leftoverCount: entry.items.count - 1,
                                    totalBytes: entry.items.reduce(0) { $0 + $1.bytes }, label: nil, warning: nil),
                        isCurrent: false, isSelected: true, progress: entry.state, isLocked: true,
                        onToggle: { _ in }, onSelect: {})
                }
            }
            }
            .padding(8)
        }
        .arrowKeyList(shown.map(\.id), current: currentID(shown), proxy: proxy) { current = $0 }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
        }
    }

    private func currentID(_ shown: [AppRow]) -> URL? {
        if let current, shown.contains(where: { $0.id == current }) { return current }
        return shown.first?.id
    }

    // MARK: Right pane

    @ViewBuilder private func rightPane(_ shown: [AppRow]) -> some View {
        let model = models.uninstaller
        switch phase {
        case .removing:
            if let progress = model.progress { RemovingView(progress: progress, home: models.homeDirectory) }
        case .done:
            if let result = model.result {
                UninstallSummaryView(summary: UninstallSummary.make(
                    records: result.records, stopped: result.stopped, home: models.homeDirectory))
            }
        case .list, .limited:
            let row = currentID(shown).flatMap { id in shown.first { $0.id == id } }
            LoadingSwap(isLoading: row == nil && model.isLoading) {
                // The detail pane itself, for a placeholder app, drawn as its skeleton.
                AppDetailPane(row: .placeholder(0), isPlaceholder: true)
            } content: {
                if let row {
                    AppDetailPane(row: row)
                } else {
                    PickAnApp(text: "Pick an app")
                }
            }
        }
    }

    // MARK: Action bar

    @ViewBuilder private var actionBar: some View {
        let model = models.uninstaller
        switch phase {
        case .limited:
            ActionBar(title: "No apps listed", caption: "Needs Full Disk Access to look for leftovers") {
                Button(action: {}) {
                    HStack(spacing: 6) {
                        PixelIconView(.trash, tint: .foreground)
                        Text("Move to Trash")
                    }
                }
                .dustlingPrimary()
                .disabled(true)
            }
        case .list:
            let confirm = model.confirmation
            let line = UninstallerScreen.selectionLine(confirm)
            ActionBar(title: line.title, caption: line.caption) {
                Button("Review all files") { reviewing = true }
                    .disabled(!confirm.ready || model.isRestoring)
                    .help("Every file of the selected apps, to leave any of them where they are")
                Button(action: {
                    model.clearRefusal()
                    confirming = model.confirmation
                }) {
                    HStack(spacing: 6) {
                        PixelIconView(.trash, tint: .foreground)
                        Text("Move to Trash")
                    }
                }
                .dustlingPrimary()
                .disabled(!confirm.ready || model.isRestoring)
                .help(confirm.ready ? "Shows everything that will move and asks first" : line.caption)
            }
        case .removing:
            removingBar
        case .done:
            // What is in the Trash now: Put back on an app takes its share out.
            let inTrash = model.result.map { model.bytesStillInTrash($0.records) } ?? 0
            // Once everything was put back, nothing of this uninstall is in the Trash: Done is next.
            let allBack = inTrash == 0 && !model.restoreOutcomes.isEmpty
            ActionBar(
                title: allBack ? "Everything is back where it was" : "\(Bytes.format(inTrash)) in the Trash",
                caption: allBack ? "Done takes you back to the list." : "Available space grows when you empty the Trash."
            ) {
                if allBack {
                    emptyTrashButton(model)
                    Button("Done") { model.dismissResult() }
                        .dustlingPrimary()
                        .disabled(model.isRestoring)
                } else {
                    Button("Done") { model.dismissResult() }
                        .disabled(model.isRestoring)
                    emptyTrashButton(model).dustlingPrimary()
                }
            }
        }
    }

    private func emptyTrashButton(_ model: UninstallerModel) -> some View {
        Button("Empty Trash…") { confirmingEmptyTrash = true }
            .disabled(!models.trash.canEmpty || models.trash.isEmptying || model.isRestoring || isFixture)
            .help(models.trash.disabledReason ?? "Shows what is in the Trash and asks before deleting it")
    }

    @ViewBuilder private var removingBar: some View {
        let model = models.uninstaller
        if let progress = model.progress {
            let total = progress.apps.count
            let place = min(total, progress.appsDone + (progress.current == nil ? 0 : 1))
            let items = progress.apps.reduce(0) { $0 + $1.items.count }
            let done = progress.apps.reduce(0) { $0 + $1.doneCount }
            let title: String = {
                guard let current = progress.current else { return "Finishing" }
                return current.state == .quitting
                    ? "Quitting \(current.app.displayName)" : "Removing \(current.app.displayName)"
            }()
            let caption = model.stopRequested
                ? "Stopping after \(progress.current?.app.displayName ?? "this app")"
                : "\(place) of \(total) \(total == 1 ? "app" : "apps"), \(Bytes.format(progress.bytesMoved)) moved so far"
            ActionBar(title: title, caption: caption, busyLabel: "Moving…") {
                ProgressBar(fraction: items == 0 ? 0 : Double(done) / Double(items))
                    .frame(width: 220)
                Button("Stop", action: model.stop)
                    .disabled(model.stopRequested)
                    .help("Finishes the app being removed now and leaves the rest alone")
            }
        }
    }

    /// The DEBUG screenshot fixture is on: nothing real may be offered.
    private var isFixture: Bool {
        #if DEBUG
        return models.uninstallerFixture
        #else
        return false
        #endif
    }

    // MARK: Uninstall

    private func start(_ confirm: ConfirmModel) {
        // The sheet's snapshot is used once and dropped.
        confirming = nil
        Task { _ = await models.uninstaller.uninstallSelected(confirmed: confirm, quit: WorkspaceAppQuitter()) }
    }
}

/// The selected app's header, its leftover rows and the "never touched" footer (`.u-prev`).
private struct AppDetailPane: View {
    let row: AppRow
    /// The loading skeleton: `row` is a placeholder and the pane draws in placeholder mode.
    var isPlaceholder = false
    @Environment(AppModels.self) private var models

    /// Leftover rows a placeholder pane shows while the first app is still being found.
    private static let placeholderLeftovers = 4
    /// Leftover rows shown under a listed app while its leftovers are still being looked for.
    private static let countingLeftovers = 3

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let model = models.uninstaller
        let leftovers = isPlaceholder ? [] : model.leftovers(for: row.app)
        let locked = model.isUninstalling || model.isRestoring
        VStack(spacing: 0) {
            header(leftovers)
                .skeleton(isPlaceholder)
            ScrollView {
                VStack(spacing: 0) {
                    if let warning = row.warning {
                        DataWarningBlock(text: warning)
                            .padding(.bottom, 6)
                    }
                    applicationLine(locked: locked)
                        .skeleton(isPlaceholder)
                    ForEach(leftovers) { leftover in
                        Hairline()
                        LeftoverRowView(row: leftover, home: models.homeDirectory, isLocked: locked) { on in
                            model.setChecked(on, leftover: leftover.leftover, in: row.app)
                        }
                    }
                    if row.isCounting || isPlaceholder {
                        let count = isPlaceholder ? Self.placeholderLeftovers : Self.countingLeftovers
                        ForEach(0..<count, id: \.self) { index in
                            Hairline()
                            LeftoverLineSkeleton(index: index + 1)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
            }
            footer
        }
    }

    private func header(_ leftovers: [LeftoverRow]) -> some View {
        let totals = UninstallerScreen.totals(app: row, leftovers: leftovers)
        return HStack(spacing: 14) {
            AppIconView(app: row.app, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.app.displayName)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 16).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .skeletonText()
                Text(isPlaceholder ? "Version 00.0.0." : detailLine)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                    .foregroundStyle(Palette.muted)
                    .skeletonText()
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Bytes.format(totals.selected))
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 20).weight(.bold))
                    .foregroundStyle(Palette.accent)
                    .contentTransition(.numericText())
                    .skeletonText()
                Text("of \(Bytes.format(totals.found)) found")
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
                    .skeletonText()
            }
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// "Version 4.37.1. Running now." Vendors aren't known (no reliable source in the bundle).
    private var detailLine: String {
        var parts: [String] = []
        if row.label == "Steam game" { parts.append("Steam game, no bundle ID") }
        else if let version = AppVersion.text(for: row.app) { parts.append("Version \(version)") }
        if models.uninstaller.isRunning(row.app) { parts.append("Running now") }
        if let id = row.app.bundleID, parts.isEmpty { parts.append(id) }
        return parts.isEmpty ? "" : parts.joined(separator: ". ") + "."
    }

    /// The app itself, first in the list. Its checkbox is the same as the one in the left pane.
    private func applicationLine(locked: Bool) -> some View {
        let model = models.uninstaller
        let isLink = row.app.linkTarget != nil
        return LeftoverLine(
            title: isLink ? "Shortcut" : "Application",
            path: UninstallerScreen.path(row.app.url, home: models.homeDirectory),
            size: isLink ? "Link" : Bytes.format(row.app.bytes)
        ) {
            Toggle(isOn: Binding(
                get: { model.selection.contains(row.id) },
                set: { on in if on { model.selection.insert(row.id) } else { model.selection.remove(row.id) } }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(locked)
                .accessibilityLabel("Remove \(row.app.displayName)")
        } detail: {
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            PixelIconView(.shield, color: Palette.success)
            Text("Documents you made with \(isPlaceholder ? "an app" : row.app.displayName) are never touched. "
                 + "Data items stay unchecked unless you check them.")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 22)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// The empty right pane: sleepy Mote and one line ("Pick an app").
private struct PickAnApp: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            MoteView(.sleepy, pixel: 3)
            Text(text)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                .foregroundStyle(DustlingTheme.Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension UninstallProgress.AppEntry {
    /// A removed app's row ID, distinct from its list row's (the app URL).
    var removedRowID: String { "removed:" + id.absoluteString }
}

/// The action bar's 6 pt progress track (`.w-prog`): `panel` track, accent fill.
private struct ProgressBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DustlingTheme.Palette.panel)
                Capsule().fill(DustlingTheme.Palette.accent)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
                    .animation(DustlingTheme.Motion.animation(.easeOut(duration: 0.35), reduceMotion: reduceMotion), value: fraction)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// An app's version from its Info.plist, read once per app. The DEBUG fixture supplies its own.
@MainActor enum AppVersion {
    private static var cache: [URL: String?] = [:]
    #if DEBUG
    static var fixture: [URL: String] = [:]
    #endif

    static func text(for app: InstalledApp) -> String? {
        #if DEBUG
        if let version = fixture[app.url] { return version }
        #endif
        if let known = cache[app.url] { return known }
        let info = Bundle(url: app.url)?.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        cache[app.url] = version
        return version
    }
}
