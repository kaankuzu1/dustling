import DustlingAppModel
import SwiftUI

/// Step 4. The approved mockups name this step but don't draw it, so it reuses their copy: the O06
/// granted state ("Dustling can see everything now") with "Start scanning", or the limited-mode
/// wording from O07 when places are still locked.
struct ReadyStep: View {
    let start: () -> Void
    @Environment(AppModels.self) private var models

    private var locked: [Place] { models.places.lockedPlaces }
    private var seesEverything: Bool {
        models.places.places != nil && models.places.readableCount == models.places.total
    }

    /// What Full Disk Access would open, then (like the Full Disk Access step) any places that can't
    /// be read for another reason.
    private var lockedCaption: String {
        [models.places.lockedSentence, LimitedModeBanner.honesty, models.places.unreadableSentence]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 96 pt (6 pt per pixel): the integer scale the design chose for the mockups' 72 pt Mote.
            MoteView(seesEverything ? .happy : .worried, pixel: 6)
            if models.places.places == nil {
                StepHeadline.placeholder
            } else if seesEverything {
                StepHeadline(
                    title: "Dustling can see everything now",
                    caption: "All \(models.places.total) places are open.",
                    small: true)
            } else if locked.isEmpty {
                // Nothing needs Full Disk Access; some places can't be read for another reason.
                StepHeadline(
                    title: "Dustling can see \(models.places.readableCount) of \(models.places.total) places",
                    caption: models.places.unreadableSentence,
                    small: true)
            } else {
                StepHeadline(
                    title: LimitedModeBanner.title(lockedCount: locked.count),
                    caption: lockedCaption,
                    small: true)
            }
            Button("Start scanning") {
                models.onboarding.complete(.ready)
                start()
                // A fresh scan, as the button says: the one from launch may be minutes old by now.
                // Nothing happens if that one is still running.
                models.scanJunk()
            }
                .dustlingPrimary()
                .keyboardShortcut(.defaultAction)
        }
    }
}
