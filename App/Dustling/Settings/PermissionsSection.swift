import DustlingAppModel
import DustlingCore
import SwiftUI

/// Permissions and helper (SCREENS-final §7, the "Health check" frame): the live checks with Repair,
/// Check again, and the ways on: the onboarding at the right step, Diagnostics, and the report.
struct PermissionsSection: View {
    @Environment(AppModels.self) private var models
    @Environment(\.openWindow) private var openWindow
    @State private var logFolder: Diagnostics.LogFolderState = .notCreatedYet
    @State private var checking = false
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        TimelineView(.everyMinute) { context in
            let checks = models.diagnosticChecks(logFolder: logFolder, now: context.date)
            let working = Diagnostics.allWorking(checks)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    MoteView(working ? .happy : .worried, pixel: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(working ? "Everything is working" : "Something needs you")
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 15).weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        Text("Dustling runs these checks when it opens and each time you come back to it.")
                            .font(DustlingTheme.Typography.caption)
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 8)
                    if checking { BusyIndicator(label: "Checking…") }
                    Button(action: checkAgain) {
                        HStack(spacing: 6) {
                            PixelIconView(.refresh, tint: .foreground)
                            Text("Check again")
                        }
                    }
                    .disabled(checking)
                }
                HealthCheckList(checks: checks) { fix in repair(fix) }
                SettingsForm {
                    FormRow(title: "Set up permissions again",
                            detail: "Walks through Full Disk Access and the cleanup helper.") {
                        Button("Open") { models.openOnboarding(at: onboardingStep, using: openWindow) }
                            .controlSize(.small)
                    }
                    FormRow(title: "Diagnostics", detail: "Every check, the last run's problems and the log folder.") {
                        Button("Open") {
                            models.selection = .diagnostics
                            openWindow(id: "main")
                        }
                        .controlSize(.small)
                    }
                    FormRow(title: "Copy a diagnostics report",
                            detail: "For a GitHub issue. Contains no file names from your home folder.") {
                        CopyReportButton(title: "Copy", logFolder: logFolder)
                    }
                }
            }
        }
        .task { logFolder = await Diagnostics.readLogFolderInBackground(models.logsDirectory) }
    }

    /// The first step that still needs the user: Full Disk Access while it is off, else the helper.
    private var onboardingStep: OnboardingStep {
        models.health.fullDiskAccess == .granted ? .permissions : .fullDiskAccess
    }

    /// Full Disk Access is repaired in the onboarding's Full Disk Access step (live status, deep link
    /// and the drag tile). The other repairs work as in the health popover.
    private func repair(_ fix: FixAction) {
        if fix == .openFullDiskAccessSettings {
            models.openOnboarding(at: .fullDiskAccess, using: openWindow)
        } else {
            HealthFix.perform(fix, models: models)
        }
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
