import AppKit
import DustlingAppModel
import SwiftUI

/// About (SCREENS-final §7): version, the MIT licence, GitHub and the logs folder. There is no update
/// check, because Dustling doesn't use the network. The Homebrew row waits for the cask.
struct AboutSection: View {
    static let repository = URL(string: "https://github.com/kaankuzu1/dustling")!
    @Environment(AppModels.self) private var models
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(spacing: 12) {
            AppIconTile(size: 96)
            Text("Dustling")
                .font(.custom(DustlingTheme.Typography.lockupFamily, size: 28).weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text("Version \(Self.version)")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
            Button("View on GitHub") {
                if !NSWorkspace.shared.open(Self.repository) {
                    NSLog("Dustling: couldn't open \(Self.repository)")
                    let alert = NSAlert()
                    alert.messageText = "The link didn't open"
                    alert.informativeText = "Dustling's source code is at \(Self.repository.absoluteString)."
                    ModalAlert.show(alert)
                }
            }
            .help(Self.repository.absoluteString)
            SettingsForm {
                FormRow(title: "Licence", detail: "MIT. Free and open source.") { EmptyView() }
                FormRow(title: "Logs", detail: models.logsDisplayPath, mono: true) {
                    Button("Show") { models.openLogFolder() }
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// "0.1.0 (1)".
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(short) (\(build))"
    }
}
