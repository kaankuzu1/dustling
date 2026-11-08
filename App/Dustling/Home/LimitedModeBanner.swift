import DustlingAppModel
import SwiftUI

/// Limited mode (O07 in the approved mockups): the banner at the top of Home when places Dustling
/// scans are locked because Full Disk Access is off. "Grant access" reopens onboarding at the Full Disk
/// Access step.
struct LimitedModeBanner: View {
    @Environment(AppModels.self) private var models
    @Environment(\.openWindow) private var openWindow

    /// Shown once Full Disk Access is known to be off (or unverified), the places check has run and
    /// at least one place needs access. Never while access is on: then nothing is blamed on it.
    @MainActor static func isShown(_ models: AppModels) -> Bool {
        models.hasProbedFullDiskAccess
            && models.health.fullDiskAccess != .granted
            && models.places.places != nil
            && !models.places.lockedPlaces.isEmpty
    }

    static func title(lockedCount: Int) -> String {
        lockedCount == 1
            ? "Limited scan: 1 place needs Full Disk Access"
            : "Limited scan: \(lockedCount) places need Full Disk Access"
    }

    /// The Home toolbar subtitle in limited mode.
    static func subtitle(lockedCount: Int) -> String {
        lockedCount == 1
            ? "Limited mode: 1 place needs Full Disk Access"
            : "Limited mode: \(lockedCount) places need Full Disk Access"
    }

    static let honesty = "It never shows 0 bytes for a place it couldn't read."

    var body: some View {
        let locked = models.places.lockedPlaces
        Banner(
            title: Self.title(lockedCount: locked.count) + ".",
            message: [models.places.lockedSentence, Self.honesty].compactMap { $0 }.joined(separator: " "),
            leading: .worriedMote
        ) {
            Button("Grant access") { models.openOnboarding(at: .fullDiskAccess, using: openWindow) }
                .dustlingPrimary()
        }
    }
}
