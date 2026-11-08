import AppKit
import DustlingAppModel
import ServiceManagement
import SwiftUI

/// General (SCREENS-final §7): open at login, the locked Empty Trash confirmation, and Appearance.
/// "Show in the menu bar" and the Trash-size notification are left out of v1 (Ruling R33).
struct GeneralSection: View {
    @Environment(AppModels.self) private var models
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        @Bindable var settings = models.settings
        VStack(alignment: .leading, spacing: 8) {
            SettingsForm {
                FormRow(title: "Open Dustling at login",
                        detail: "Off by default. Dustling doesn't need to run in the background.") {
                    SettingsSwitch(label: "Open Dustling at login", isOn: Binding(
                        get: { settings.openAtLogin },
                        set: { settings.setOpenAtLogin($0) }))
                }
                FormRow(title: "Always confirm before emptying the Trash",
                        detail: "This is the only permanent step, so it can't be turned off.") {
                    SettingsSwitch(label: "Always confirm before emptying the Trash", isOn: .constant(true))
                        .disabled(true)
                        .help("Empty Trash always asks first")
                }
                FormRow(title: "Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
            if let note = settings.loginItemNote {
                HStack(spacing: 8) {
                    PixelIconView(.warn, color: Palette.warning)
                    Text(note)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if settings.loginItemNeedsApproval {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: settings.appearance) { _, appearance in Appearance.apply(appearance) }
    }
}

/// Applies Settings > Appearance to every window. "Match system" follows macOS.
@MainActor
enum Appearance {
    static func apply(_ setting: AppearanceSetting) {
        switch setting {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
