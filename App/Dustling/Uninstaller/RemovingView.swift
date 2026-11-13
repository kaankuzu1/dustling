import DustlingAppModel
import DustlingCore
import SwiftUI

/// The Removing state (`progressPane()` in the approved mockups): what has moved so far, then app by
/// app each item with a spinner, then a check. Apps that haven't started yet aren't listed here; the
/// left pane shows them waiting.
struct RemovingView: View {
    let progress: UninstallProgress
    let home: URL

    private typealias Palette = DustlingTheme.Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    MoteView(.idle, pixel: 2)
                    (Text(Bytes.format(progress.bytesMoved)).font(DustlingTheme.Typography.figure)
                     + Text(" moved so far").font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.medium))
                        .foregroundStyle(Palette.muted))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
                ForEach(progress.apps.filter { $0.state != .waiting }) { entry in
                    AppProgressSection(entry: entry, home: home)
                        .id(entry.id)
                }
            }
            .padding(DustlingTheme.Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The app being removed now stays in view as earlier ones finish.
        .task(id: progress.current?.id) {
            guard let id = progress.current?.id else { return }
            withAnimation(DustlingTheme.Motion.animation(.easeOut(duration: 0.3), reduceMotion: reduceMotion)) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
        }
    }
}

private struct AppProgressSection: View {
    let entry: UninstallProgress.AppEntry
    let home: URL

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                AppIconView(app: entry.app, size: 20)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                Text(entry.app.displayName)
                    .font(DustlingTheme.Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(entry.items.count == 1 ? "1 item" : "\(entry.items.count) items")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                state
                    .font(DustlingTheme.Typography.size)
            }
            .lineLimit(1)
            .monospacedDigit()
            .padding(.top, 12)
            .padding(.bottom, 6)
            if entry.state != .stopped {
                VStack(spacing: 0) {
                    ForEach(Array(entry.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Hairline() }
                        itemRow(item)
                    }
                }
            }
        }
    }

    @ViewBuilder private var state: some View {
        switch entry.state {
        case .finished(removed: true): Text("Done").foregroundStyle(Palette.success)
        case .finished(removed: false): Text("Left alone").foregroundStyle(Palette.warning)
        case .stopped: Text("Stopped, nothing moved").foregroundStyle(Palette.muted)
        case .quitting: Text("Quitting…").foregroundStyle(Palette.ink)
        case .removing, .waiting: Text("\(entry.doneCount) of \(entry.items.count)").foregroundStyle(Palette.ink)
        }
    }

    private func itemRow(_ item: UninstallProgress.Item) -> some View {
        LeftoverLine(
            title: item.title, path: UninstallerScreen.path(item.url, home: home), size: trailing(item)
        ) {
            switch item.state {
            case .waiting: Ring()
            case .moving: BusyIndicator(label: "Moving…")
            case .finished(.movedToTrash): CheckMark()
            case .finished: PixelIconView(.warn, color: Palette.warning)
            }
        } detail: {
            if case .finished(let outcome) = item.state, let reason = Self.reason(outcome) {
                Text(reason)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                    .foregroundStyle(Palette.warning)
            }
        }
        .opacity(Self.isMoved(item) ? 0.6 : 1)
    }

    private static func isMoved(_ item: UninstallProgress.Item) -> Bool {
        if case .finished(.movedToTrash) = item.state { return true }
        return false
    }

    private func trailing(_ item: UninstallProgress.Item) -> String {
        switch item.state {
        case .waiting: return ""
        case .moving: return "Moving…"
        case .finished(.movedToTrash): return "Moved"
        case .finished(.needsAdmin): return "Not moved"
        case .finished(.skipped): return "Skipped"
        case .finished(.failed): return "Failed"
        case .finished(.deleted): return "Deleted"
        }
    }

    /// The reason under an item that didn't move (never fail silently).
    private static func reason(_ outcome: DeletionOutcome) -> String? {
        switch outcome {
        case .movedToTrash, .deleted: return nil
        case .needsAdmin: return UninstallerScreen.passwordNote
        case .skipped(let reason), .failed(let reason): return UninstallerScreen.sentence(reason)
        }
    }
}

/// An item still waiting its turn: an empty 14 pt ring (`.ring`).
private struct Ring: View {
    var body: some View {
        Circle()
            .strokeBorder(DustlingTheme.Palette.line, lineWidth: 1.5)
            .frame(width: 14, height: 14)
            .accessibilityLabel("Waiting")
    }
}

/// After the uninstall: happy Mote and the counted-up total, the sentence, then each app with what
/// happened, its problems with reasons, and Put back (or Show in Trash without Full Disk Access).
struct UninstallSummaryView: View {
    let summary: UninstallSummary

    @Environment(AppModels.self) private var models
    @State private var problem: String?

    private typealias Palette = DustlingTheme.Palette

    /// Every app that moved something was put back, in full: the header says so instead of a total.
    private var everythingPutBack: Bool {
        let moved = summary.apps.filter { $0.movedBytes > 0 }
        guard !moved.isEmpty else { return false }
        return moved.allSatisfy { line in
            guard let outcomes = models.uninstaller.restoreOutcomes[line.record.id], !outcomes.isEmpty else { return false }
            return outcomes.allSatisfy { if case .restored = $0 { true } else { false } }
        }
    }

    private var putBackLine: String {
        let moved = summary.apps.filter { $0.movedBytes > 0 }
        if moved.count == 1, let line = moved.first { return "\(line.name) and its files are back where they were." }
        return "The apps and their files are back where they were."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    MoteView(everythingPutBack ? .idle : .happy, pixel: 3)
                    VStack(alignment: .leading, spacing: 6) {
                        if everythingPutBack {
                            Text("Everything was put back")
                                .font(DustlingTheme.Typography.figure)
                                .foregroundStyle(Palette.ink)
                                .accessibilityAddTraits(.isHeader)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                CountUpText(bytes: summary.movedBytes)
                                    .font(DustlingTheme.Typography.figureLarge)
                                    .foregroundStyle(Palette.success)
                                Text("moved to the Trash")
                                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.medium))
                                    .foregroundStyle(Palette.muted)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Text(everythingPutBack ? putBackLine : summary.sentence)
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(summary.apps) { line in appLine(line) }
                if let problem {
                    Text(problem)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                        .foregroundStyle(Palette.warning)
                }
            }
            .padding(DustlingTheme.Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func appLine(_ line: UninstallSummary.AppLine) -> some View {
        let restored = models.uninstaller.restoreOutcomes[line.record.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if JunkSummary.everythingRestored(restored) {
                    PixelIconView(.undo, color: Palette.success).accessibilityLabel("Put back")
                } else if line.removed {
                    CheckMark()
                } else {
                    PixelIconView(.warn, color: Palette.warning)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.name)
                        .font(DustlingTheme.Typography.rowTitle)
                        .foregroundStyle(Palette.ink)
                    Text(restored.map(JunkSummary.restoreLine) ?? line.status)
                        .font(DustlingTheme.Typography.caption)
                        .foregroundStyle(line.removed ? Palette.muted : Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if line.movedBytes > 0 {
                    Text(Bytes.format(line.movedBytes))
                        .font(DustlingTheme.Typography.size)
                        .foregroundStyle(Palette.ink)
                }
                if line.canPutBack && restored == nil {
                    undoButton(line)
                }
            }
            if !line.problems.isEmpty && restored == nil {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(line.problems.prefix(5).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.path)
                                .font(DustlingTheme.Typography.path)
                                .foregroundStyle(Palette.ink2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.reason)
                                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                                .foregroundStyle(Palette.warning)
                                .lineLimit(1)
                        }
                    }
                    if line.problems.count > 5 {
                        Text("and \(line.problems.count - 5) more in the log")
                            .font(DustlingTheme.Typography.caption)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
    }

    @ViewBuilder private func undoButton(_ line: UninstallSummary.AppLine) -> some View {
        let model = models.uninstaller
        if model.canTakeOutOfTrash {
            Button("Put back") { putBack(line.record) }
                .disabled(model.isRestoring || model.isUninstalling)
                .help("Moves \(line.name) and its leftovers back where they were")
        } else {
            Button("Show in Trash") { models.showTrashInFinder() }
                .help("Without Full Disk Access, drag the items out of the Trash in Finder")
        }
    }

    private func putBack(_ record: RunRecord) {
        problem = nil
        Task {
            do {
                _ = try await models.uninstaller.putBack(record)
            } catch {
                NSLog("Dustling: Put back of \(record.id) didn't run: \(error)")
                problem = "Put back didn't run: \(error.localizedDescription)"
            }
        }
    }
}
