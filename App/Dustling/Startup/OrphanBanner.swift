import DustlingAppModel
import SwiftUI

/// The orphaned-item banner (SCREENS-final §5): worried Mote, "Logi Options+ was uninstalled, but its
/// startup item still runs.", with Turn off and Remove…. Turning off is the main, reversible action;
/// Remove confirms first. Items that need the helper get no buttons that can't work.
struct OrphanBannerView: View {
    let text: StartupScreen.OrphanBannerText
    let onTurnOff: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Banner(title: text.title, message: text.message, leading: .worriedMote) {
            if text.showsTurnOff {
                Button("Turn off", action: onTurnOff)
            }
            if text.showsRemove {
                Button("Remove…", action: onRemove)
            }
        }
    }
}
