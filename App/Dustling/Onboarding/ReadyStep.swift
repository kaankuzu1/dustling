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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 64 pt: the nearest integer scale to the mockups' 72 pt Mote.
            MoteView(seesEverything ? .happy : .worried, pixel: 4)
            if models.places.places == nil {
                SkeletonBlock(width: 420, height: 30)
                    .accessibilityElement()
                    .accessibilityLabel("Checking which places Dustling can see")
            } else if seesEverything {
                StepHeadline(
                    title: "Dustling can see everything now",
                    caption: "All \(models.places.total) places are open.",
                    small: false, captionSize: 14)
            } else if locked.isEmpty {
                // Nothing needs Full Disk Access; some places can't be read for another reason.
                StepHeadline(
                    title: "Dustling can see \(models.places.readableCount) of \(models.places.total) places",
                    caption: models.places.unreadableSentence,
                    small: false, captionSize: 14)
            } else {
                StepHeadline(
                    title: LimitedModeBanner.title(lockedCount: locked.count),
                    caption: models.places.lockedSentence.map { "\($0) \(LimitedModeBanner.honesty)" },
                    small: false, captionSize: 14)
            }
            Button("Start scanning", action: start)
                .dustlingPrimary()
                .keyboardShortcut(.defaultAction)
        }
    }
}
