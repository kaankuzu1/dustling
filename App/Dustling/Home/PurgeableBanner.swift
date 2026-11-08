import DustlingAppModel
import SwiftUI

/// The plain-words info banner under the hero (spec §7.2b, mockup H03): shown when 2 GB or more is
/// purgeable. macOS manages that space, and it explains why emptying the Trash can lag.
struct PurgeableBanner: View {
    let notice: PurgeableNotice

    var body: some View {
        Banner(title: notice.title, message: notice.message, tone: .info, leading: .icon(.info))
    }
}
