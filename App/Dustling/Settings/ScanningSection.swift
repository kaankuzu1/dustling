import DustlingAppModel
import SwiftUI

/// Scanning (SCREENS-final §7): what the junk scan covers. The values are `ScanOptions` (Task 4) and
/// three toggles over the catalog; they apply from the next scan.
struct ScanningSection: View {
    @Environment(AppModels.self) private var models
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        @Bindable var settings = models.settings
        VStack(alignment: .leading, spacing: 8) {
            if let problem = settings.loadProblem {
                Banner(title: "Scan settings were reset", message: problem, leading: .icon(.warn))
            }
            SettingsForm {
                FormRow(title: "Preselect safe categories", detail: "Caches, logs, Xcode data and package downloads.") {
                    SettingsSwitch(label: "Preselect safe categories", isOn: $settings.preselectSafe)
                }
                FormRow(title: "Show review items",
                        detail: "Old installers, iPhone backups, Mail downloads. Never preselected.") {
                    SettingsSwitch(label: "Show review items", isOn: $settings.showReviewItems)
                }
                FormRow(title: "Skip files changed in the last", detail: "Protects anything an app is still using.") {
                    Picker("Skip files changed in the last", selection: $settings.skipChangedWithinDays) {
                        ForEach(AppSettings.skipDayChoices, id: \.self) { days in
                            Text(AppSettings.skipTitle(days)).tag(days)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                FormRow(title: "Include Trash on external drives") {
                    SettingsSwitch(label: "Include Trash on external drives", isOn: $settings.includeExternalTrash)
                }
                FormRow(title: "Browser caches", detail: "Never history, cookies or passwords.") {
                    SettingsSwitch(label: "Browser caches", isOn: $settings.includeBrowserCaches)
                }
            }
            Text("Changes apply from the next scan.")
                .font(DustlingTheme.Typography.caption)
                .foregroundStyle(Palette.muted)
        }
    }
}
