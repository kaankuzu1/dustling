import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// The running apps the close-apps sheet may offer: regular apps with a bundle, never Dustling
/// itself or background processes.
enum OpenApps {
    @MainActor static func regular() -> [RunningApp] {
        let me = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier, id != me,
                  let url = app.bundleURL else { return nil }
            return RunningApp(bundleID: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, bundleURL: url)
        }
    }

    /// Every running bundle ID, for in-use re-checks (as the scan sees them).
    nonisolated static func allBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
    }
}

/// "Close Safari to include its files?": shown at Move to Trash when open apps hold selected files.
/// Dustling asks each app to quit (never forces it), shows how each one went, re-checks which files
/// are free, and then cleans. If fewer files can move than offered, it says so and asks again.
struct CloseAppsSheet: View {
    let run: CloseAppsRun
    #if DEBUG
    /// Screenshot fixtures only: statuses to show, and buttons that do nothing.
    var fixtureStatuses: [String: CloseApps.Status]?
    private var isFixture: Bool { fixtureStatuses != nil }
    #else
    private var isFixture: Bool { false }
    #endif

    @Environment(AppModels.self) private var models
    @Environment(\.dismiss) private var dismiss
    @State private var promised: UInt64 = 0
    /// What moves without the apps' files.
    @State private var withoutThem: UInt64 = 0
    /// Set once the apps have finished and what can move isn't what was offered.
    @State private var changedTo: UInt64?
    @State private var changedLine: String?

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let gate = models.junk.cleanupGate
        VStack(alignment: .leading, spacing: 14) {
            Text(CloseApps.title(run.holders))
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 15).weight(.semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(run.holders) { holder in
                    AppRow(holder: holder, status: status(holder))
                }
            }
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
            Text(CloseApps.note)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if gate.kind == .confirmFirst, let note = gate.note {
                // Limited mode: never dropped, whichever way the user cleans.
                Text(note)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = changedLine {
                Text(line)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.warning)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(changedTo == nil ? "\(Bytes.format(promised)) will move" : "\(Bytes.format(changedTo ?? 0)) will move")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(run.isRunning)
                if let changedTo {
                    Button("Move \(Bytes.format(changedTo)) to Trash") { clean(closed: run.closedNames) }
                        .dustlingPrimary()
                } else {
                    Button("Clean without them (\(Bytes.format(withoutThem)))") { clean(closed: []) }
                        .monospacedDigit()
                        .disabled(run.isRunning)
                    Button("Quit apps and clean", action: quitAndClean)
                        .dustlingPrimary()
                        .disabled(run.isRunning || run.isFinished)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Palette.ground)
        .interactiveDismissDisabled(run.isRunning)
        .onAppear {
            withoutThem = models.junk.selectedBytes
            promised = withoutThem + run.holders.reduce(0) { $0 + $1.bytes }
        }
    }

    private func status(_ holder: OpenAppHolder) -> CloseApps.Status {
        #if DEBUG
        if let fixture = fixtureStatuses?[holder.bundleID] { return fixture }
        #endif
        return run.statuses[holder.bundleID] ?? .waiting
    }

    private func clean(closed: [String]) {
        guard !isFixture else { return }
        dismiss()
        let skip = models.cleanupSkip
        // Both buttons count as confirming: this sheet shows the limited-mode note when it applies.
        Task { await models.junk.clean(skipping: skip, confirmedLimited: true, closedApps: closed) }
    }

    private func quitAndClean() {
        guard !isFixture else { return }
        Task {
            // Quits, re-checks only these apps, and cleans if exactly the offered amount can move.
            switch await models.junk.quitAndCleanFlow(run, quitter: WorkspaceAppQuitter(), promised: promised) {
            case .cleaned:
                dismiss()
            case .askAgain(let now, let line):
                // Say so and ask again: the confirmed figure must be what is attempted.
                changedTo = now
                changedLine = line
            }
        }
    }
}

private struct AppRow: View {
    let holder: OpenAppHolder
    let status: CloseApps.Status

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: DustlingTheme.Metrics.columnGap) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: holder.bundleURL.path(percentEncoded: false)))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(holder.name)
                    .font(DustlingTheme.Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                Text("\(Bytes.format(holder.bytes)) of junk waiting")
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            statusView
        }
        .padding(DustlingTheme.Metrics.rowPadding)
        .frame(minHeight: DustlingTheme.Metrics.rowMinHeight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .waiting:
            EmptyView()
        case .closing:
            HStack(spacing: 6) {
                if !reduceMotion { ProgressView().controlSize(.small) }
                Text(CloseApps.statusText(.closing))
            }
            .font(DustlingTheme.Typography.caption)
            .foregroundStyle(Palette.muted)
        case .closed:
            HStack(spacing: 6) {
                CheckMark()
                Text(CloseApps.statusText(.closed))
            }
            .font(DustlingTheme.Typography.caption)
            .foregroundStyle(Palette.success)
        case .stillOpen:
            Text(CloseApps.statusText(.stillOpen))
                .font(DustlingTheme.Typography.caption)
                .foregroundStyle(Palette.warning)
        }
    }
}
