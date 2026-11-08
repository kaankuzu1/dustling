import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// The Diagnostics page (E08 in the approved mockups), in the main window: each check with its last
/// result and a repair where one can work, the last run's problem rows, Copy diagnostics report and
/// the log folder. Reached from the health popover and Settings > Permissions and helper.
struct DiagnosticsView: View {
    @Environment(AppModels.self) private var models
    @State private var logFolder: Diagnostics.LogFolderState = .notCreatedYet
    @State private var checking = false
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.everyMinute) { context in
                ScreenToolbar(title: "Dustling health", subtitle: subtitle(now: context.date)) {
                    if checking {
                        BusyIndicator(label: "Checking…")
                    }
                    Button(action: checkAgain) {
                        HStack(spacing: 6) {
                            PixelIconView(.refresh, tint: .foreground)
                            Text("Check again")
                        }
                    }
                    .disabled(checking)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TimelineView(.everyMinute) { context in
                        HealthCheckList(checks: models.diagnosticChecks(logFolder: logFolder, now: context.date)) { fix in
                            HealthFix.perform(fix, models: models)
                        }
                    }
                    if let run = models.health.lastRun {
                        LastRunProblems(run: run)
                    }
                    SettingsForm {
                        FormRow(title: "Copy diagnostics report",
                                detail: "macOS version, app version, check results. No file names from your home folder.") {
                            CopyReportButton(title: "Copy report", logFolder: logFolder)
                        }
                        FormRow(title: "Open the log folder", detail: models.logsDisplayPath) {
                            Button("Show") { models.openLogFolder() }
                                .controlSize(.small)
                        }
                    }
                }
                .padding(DustlingTheme.Metrics.gutter)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.ground)
        .task { logFolder = await Diagnostics.readLogFolderInBackground(models.logsDirectory) }
    }

    private func subtitle(now: Date) -> String {
        guard models.hasProbedFullDiskAccess, let at = models.health.lastProbeAt else { return "Checking…" }
        return Diagnostics.checkedAgo(at, now: now)
    }

    private func checkAgain() {
        checking = true
        Task {
            if await models.health.refresh() { await models.refreshPlaces() }
            logFolder = await Diagnostics.readLogFolderInBackground(models.logsDirectory)
            checking = false
        }
    }
}

extension AppModels {
    /// `~/Library/Logs/Dustling`, for the screen only (never in the report).
    var logsDisplayPath: String {
        let home = homeDirectory.path(percentEncoded: false)
        let path = logsDirectory.path(percentEncoded: false)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.hasPrefix(trimmedHome + "/") ? "~" + trimmed.dropFirst(trimmedHome.count) : trimmed
    }

    func diagnosticChecks(logFolder: Diagnostics.LogFolderState, now: Date = .now) -> [Diagnostics.Check] {
        Diagnostics.checks(Diagnostics.Input(
            fullDiskAccess: health.fullDiskAccess, published: hasProbedFullDiskAccess, checkedAt: health.lastProbeAt,
            now: now, helper: health.helper, logFolder: logFolder, logFolderDisplay: logsDisplayPath))
    }

    /// The text "Copy diagnostics report" puts on the clipboard.
    func diagnosticsReport(logFolder: Diagnostics.LogFolderState) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return DiagnosticsReport.make(DiagnosticsReport.Input(
            macOS: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: "\(version) (\(build))", checks: diagnosticChecks(logFolder: logFolder),
            lastRun: health.lastRun, home: homeDirectory, generatedAt: .now))
    }
}

/// Copies the diagnostics report and says so next to the button.
struct CopyReportButton: View {
    let title: String
    let logFolder: Diagnostics.LogFolderState
    @Environment(AppModels.self) private var models
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            if copied {
                Text("Copied")
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(DustlingTheme.Palette.success)
            }
            Button(title) {
                let board = NSPasteboard.general
                board.clearContents()
                copied = board.setString(models.diagnosticsReport(logFolder: logFolder), forType: .string)
                if !copied { NSLog("Dustling: couldn't put the diagnostics report on the clipboard") }
            }
            .controlSize(.small)
        }
    }
}

/// The checks as rows (the mockups' `health()`): a status dot, the check and its last result, a chip,
/// and Repair where a repair can work. The helper is "Not available yet" in v1 and has no button.
struct HealthCheckList: View {
    let checks: [Diagnostics.Check]
    let repair: (FixAction) -> Void
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(spacing: 8) {
            ForEach(checks) { check in
                HStack(spacing: 14) {
                    HealthDot(state: check.state.lightState)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title)
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        Text(check.detail)
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Chip(text: check.chip, kind: check.state.chipKind, onPanel: true)
                    if let fix = check.repair {
                        Button("Repair") { repair(fix) }
                            .dustlingPrimary()
                            .controlSize(.small)
                            .help(fix.title)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
                .accessibilityElement(children: .contain)
            }
        }
    }
}

private extension Diagnostics.Check.State {
    var lightState: HealthLight.State {
        switch self {
        case .ok: return .ok
        case .warning: return .warning
        case .info, .checking: return .info
        }
    }

    var chipKind: Chip.Kind {
        switch self {
        case .ok: return .success
        case .warning: return .warning
        case .info, .checking: return .neutral
        }
    }
}

/// The last run's problem rows (the mockups' `failRows`): item, result, reason and fix, under the
/// run's totals and Retry N items. Nothing shows when the run had no problems.
private struct LastRunProblems: View {
    let run: RunRecord
    @Environment(AppModels.self) private var models
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let problems = LastRunReview.problems(in: run, home: models.homeDirectory) { AppModels.appName(bundleID: $0) }
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last run, \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 14).weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        Text(totals)
                            .font(DustlingTheme.Typography.caption)
                            .foregroundStyle(Palette.muted)
                            .monospacedDigit()
                    }
                    Spacer()
                    let count = LastRunReview.retryableCount(in: run)
                    if models.retry.isRetrying {
                        BusyIndicator(label: "Retrying…")
                    } else if count > 0 {
                        Button(RepairCase.itemsDidNotMove(count: count).copy.fix) {
                            HealthFix.perform(.retryItems(count: count), models: models)
                        }
                        .dustlingPrimary()
                        .controlSize(.small)
                        .disabled(models.junk.isBusy)
                        .help(models.junk.isBusy ? "Available when the current scan or cleanup finishes" : "")
                    }
                }
                if let message = models.retry.message {
                    Text(message)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ProblemRow(cells: ("Item", "Result", "Reason", ""), header: true)
                    ForEach(problems) { problem in
                        ProblemRow(problem: problem)
                    }
                }
            }
        }
    }

    private var totals: String {
        let moved = run.entries.filter { if case .movedToTrash = $0.outcome { true } else { false } }.count
        var parts = ["\(moved.formatted()) moved to the Trash"]
        if run.skippedCount > 0 { parts.append("\(run.skippedCount.formatted()) skipped") }
        if run.failedCount > 0 { parts.append("\(run.failedCount.formatted()) failed") }
        if run.needsAdminCount > 0 { parts.append("\(run.needsAdminCount.formatted()) need admin rights") }
        return parts.joined(separator: ", ")
    }
}

/// One 38 pt row of the problem table, or its header.
private struct ProblemRow: View {
    private let item: String
    private let result: LastRunReview.Problem.Result?
    private let reason: String
    private let fix: String
    private let header: Bool
    private typealias Palette = DustlingTheme.Palette

    init(cells: (String, String, String, String), header: Bool) {
        item = cells.0
        result = nil
        reason = cells.2
        fix = cells.3
        self.header = header
    }

    init(problem: LastRunReview.Problem) {
        item = problem.display
        result = problem.result
        reason = problem.reason
        switch problem.fix {
        case .quitAndRetry(let app): fix = "Quit \(app), then retry"
        case .retry: fix = "Retry"
        case nil: fix = ""
        }
        header = false
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(item)
                .font(header ? DustlingTheme.Typography.caption : DustlingTheme.Typography.path)
                .foregroundStyle(header ? Palette.muted : Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let result {
                    switch result {
                    case .skipped: Chip(text: "Skipped", kind: .warning)
                    case .failed: Chip(text: "Failed", kind: .warning)
                    case .needsAdmin: Chip(text: "Needs admin", kind: .admin)
                    }
                } else {
                    Text("Result").font(DustlingTheme.Typography.caption).foregroundStyle(Palette.muted)
                }
            }
            .frame(width: 110, alignment: .leading)
            Text(reason)
                .font(header ? DustlingTheme.Typography.caption : .custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                .foregroundStyle(header ? Palette.muted : Palette.ink)
                .lineLimit(2)
                .frame(width: 230, alignment: .leading)
            Text(fix)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: header ? 30 : 38)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Form pieces (the mockups' `.form` and `.frow`)

/// A `panel`-filled group of rows with 10 pt corners and hairlines between rows.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(FormDividers()) { content() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(DustlingTheme.Palette.panel,
                    in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
    }
}

/// Puts a hairline between the form's rows.
private struct FormDividers: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        ForEach(children) { child in
            if child.id != children.first?.id {
                Rectangle().fill(DustlingTheme.Palette.line).frame(height: 1)
            }
            child
        }
    }
}

/// One form row: title (500) and an optional caption, the control on the right. 46 pt minimum.
struct FormRow<Control: View>: View {
    let title: String
    var detail: String?
    var mono = false
    @ViewBuilder var control: () -> Control
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.medium))
                    .foregroundStyle(Palette.ink)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(mono ? DustlingTheme.Typography.path : DustlingTheme.Typography.caption)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 11)
        .frame(minHeight: 46)
        .accessibilityElement(children: .contain)
    }
}
