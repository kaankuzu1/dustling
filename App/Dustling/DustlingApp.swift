import AppKit
import SwiftUI

@main
struct DustlingApp: App {
    @State private var models: AppModels

    init() {
        DustlingTheme.registerFonts()
        let models = AppModels()
        models.start()
        _models = State(initialValue: models)
    }

    var body: some Scene {
        Window("Dustling", id: "main") {
            RootView()
                .environment(models)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(DustlingTheme.Metrics.defaultWindow)
        .windowResizability(.contentMinSize)

        // First launch, limited mode's "Grant access" and Settings > Permissions open it
        // (`AppModels.openOnboarding(at:using:)`). Only the first scene opens at launch.
        Window(OnboardingWindow.title, id: OnboardingWindow.id) {
            OnboardingWindow()
                .environment(models)
        }
        .defaultSize(width: 1000, height: 660)
        .windowResizability(.contentMinSize)

        Settings {
            // The Settings window arrives in Task 15. Until then it opens empty, never with
            // controls that don't work.
            Color.clear
                .frame(width: 560, height: 360)
                .background(DustlingTheme.Palette.ground)
        }
    }
}
