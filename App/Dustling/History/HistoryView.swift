import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// History (SCREENS-final §6, merged from R01, R03, R04 and R07): three tabs under the toolbar. Runs
/// is a timeline with a dashed line at the last Empty Trash, All items is a searchable table with
/// checkboxes, and Log is the readable log of the selected run. Every outcome is shown as it happened.
struct HistoryView: View {
    @Environment(AppModels.self) private var models
    @State private var tab: Tab = .runs
    @State private var selectedRunID: UUID?
    /// Ids of the All items rows ticked for Put back.
    @State private var checked: Set<String> = []
    /// A restore that was refused or threw, in plain words.
    @State private var refusal: String?
    @State private var confirmingEmptyTrash = false

    enum Tab: String, CaseIterable { case runs = "Runs", allItems = "All items", log = "Log" }

    private typealias Palette = DustlingTheme.Palette

    private var context: HistoryScreen.Context {
        HistoryScreen.Context(
            lastEmptyTrash: models.history.lastEmptyTrash, canTakeOutOfTrash: models.history.canTakeOutOfTrash,
            home: models.homePath)
    }

    private var selectedRun: RunRow? {
        let runs = models.history.runs
        return runs.first { $0.id == selectedRunID } ?? runs.first
    }

    var body: some View {
        let history = models.history
        VStack(spacing: 0) {
            ScreenToolbar(title: "History", subtitle: subtitle) {
                Button(action: models.openLogFolder) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").accessibilityHidden(true)
                        Text("Open log folder")
                    }
                }
            }
            HistoryTabs(selection: $tab)
            banners
            Group {
                if history.runs.isEmpty {
                    if history.isLoading {
                        VStack(spacing: 0) { ForEach(0..<5, id: \.self) { SkeletonRow(index: $0) } }
                            .padding(.horizontal, DustlingTheme.Metrics.gutter)
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        NothingYet()
                    }
                } else {
                    switch tab {
                    case .runs:
                        RunsTimeline(
                            entries: HistoryScreen.timeline(history.runs, context),
                            selectedRunID: selectedRun?.id, isRestoring: history.isRestoring,
                            onSelect: { selectedRunID = $0 },
                            onShowLog: { selectedRunID = $0; tab = .log },
                            onRestore: restore(runID:),
                            onShowInTrash: models.showTrashInFinder)
                    case .allItems:
                        AllItemsTable(context: context, checked: $checked)
                    case .log:
                        if let run = selectedRun {
                            LogTab(
                                run: run, runs: history.runs, context: context,
                                onSelectRun: { selectedRunID = $0 })
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            actionBar
        }
        .background(Palette.ground)
        // Again after an Empty Trash, which changes what can be restored.
        .task(id: models.trash.isEmptying) { await history.refresh() }
        .sheet(isPresented: $confirmingEmptyTrash) { EmptyTrashSheet() }
        #if DEBUG
        .task {
            if let fixtureTab = StartupHistoryFixture.historyTab { tab = fixtureTab }
            checked = StartupHistoryFixture.checkedItems
        }
        #endif
    }

    private var subtitle: String {
        let history = models.history
        if history.isRestoring {
            return "Putting \(history.restoringCount) \(history.restoringCount == 1 ? "item" : "items") back…"
        }
        return HistoryScreen.subtitle(history.runs, isLoading: history.isLoading)
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        let history = models.history
        VStack(spacing: 8) {
            if let summary = history.lastRestore {
                Banner(
                    title: summary.title,
                    message: summary.problems.isEmpty
                        ? "They're back where they were."
                        : summary.problems.prefix(4).joined(separator: ". ")
                            + (summary.problems.count > 4 ? ", and \(summary.problems.count - 4) more." : "."),
                    tone: summary.success ? .success : .warning,
                    leading: .icon(summary.success ? .check : .warn)
                ) {
                    Button("OK") { history.dismissRestore() }
                }
            }
            if let refusal {
                Banner(title: "Nothing was put back.", message: refusal, leading: .icon(.warn)) {
                    if !history.canTakeOutOfTrash {
                        Button("Show in Trash") { models.showTrashInFinder() }
                    }
                    Button("OK") { self.refusal = nil }
                }
            }
            if let problem = history.problem {
                Banner(title: "History may be incomplete.", message: problem, leading: .icon(.warn))
            }
            if !history.unreadableRecords.isEmpty {
                let count = history.unreadableRecords.count
                Banner(
                    title: "\(count) History \(count == 1 ? "file" : "files") couldn't be read.",
                    message: "\(count == 1 ? "That run isn't" : "Those runs aren't") listed here. The log folder still has what happened.",
                    leading: .icon(.warn)
                ) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(history.unreadableRecords)
                    }
                }
            }
        }
        .padding(.horizontal, DustlingTheme.Metrics.gutter)
        .padding(.top, hasBanner ? 12 : 0)
    }

    private var hasBanner: Bool {
        let history = models.history
        return history.lastRestore != nil || refusal != nil || history.problem != nil || !history.unreadableRecords.isEmpty
    }

    // MARK: Action bar

    @ViewBuilder private var actionBar: some View {
        let history = models.history
        let chosen = checkedItems
        if history.isRestoring {
            ActionBar(
                title: "Putting items back",
                caption: "\(history.restoringCount) \(history.restoringCount == 1 ? "item goes" : "items go") back where \(history.restoringCount == 1 ? "it was" : "they were")",
                busyLabel: "Moving…") { EmptyView() }
        } else if tab == .allItems && !chosen.isEmpty {
            ActionBar(
                title: "\(chosen.count) \(chosen.count == 1 ? "item" : "items") checked, "
                    + Bytes.format(chosen.reduce(UInt64(0)) { $0 + $1.bytes }),
                caption: "They go back where they were."
            ) {
                Button("Uncheck all") { checked = [] }
                Button("Put back") { restore(items: chosen) }
                    .dustlingPrimary()
                    .disabled(!history.canTakeOutOfTrash)
                    .help(history.canTakeOutOfTrash ? "Moves the checked items out of the Trash"
                          : HistoryModelError.cantTakeOutOfTrash.localizedDescription)
            }
        } else {
            ActionBar(
                title: "Restorable until you empty the Trash",
                caption: history.canTakeOutOfTrash
                    ? "After that, History keeps the record but can't bring files back."
                    : CleanupGate.limitedNote
            ) {
                Button("Empty Trash…") { confirmingEmptyTrash = true }
                    .disabled(!models.trash.canEmpty || models.trash.isEmptying || history.isRestoring || isFixture)
                    .help(models.trash.disabledReason ?? "Shows what is in the Trash and asks before deleting it")
            }
        }
    }

    private var isFixture: Bool {
        #if DEBUG
        return models.history.isFixture
        #else
        return false
        #endif
    }

    private var checkedItems: [HistoryItem] {
        models.history.allItems.filter { checked.contains($0.id) && $0.restorable }
    }

    // MARK: Restore

    private func restore(runID: UUID) {
        refusal = nil
        Task {
            do {
                _ = try await models.history.restore(runID: runID)
            } catch {
                refusal = error.localizedDescription
            }
        }
    }

    private func restore(items: [HistoryItem]) {
        refusal = nil
        Task {
            do {
                try await models.history.restore(items: items)
                checked = []
            } catch {
                refusal = error.localizedDescription
            }
        }
    }
}

/// The three tabs under the toolbar (`.tabs` in the mockups): the current one in ink with an accent
/// underline.
private struct HistoryTabs: View {
    @Binding var selection: HistoryView.Tab
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HistoryView.Tab.allCases, id: \.self) { tab in
                let on = tab == selection
                Button { selection = tab } label: {
                    Text(tab.rawValue)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.ink : Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(on ? Palette.accent : Color.clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, DustlingTheme.Metrics.gutter)
        .padding(.top, 10)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// No runs yet: sleepy Mote.
private struct NothingYet: View {
    var body: some View {
        VStack(spacing: 10) {
            MoteView(.sleepy, pixel: 4)
            Text("Nothing here yet")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 15).weight(.semibold))
                .foregroundStyle(DustlingTheme.Palette.ink)
            Text("Cleanups, uninstalls and startup changes show up here, with every item and what happened to it.")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                .foregroundStyle(DustlingTheme.Palette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
