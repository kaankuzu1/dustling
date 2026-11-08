import AppKit
import SwiftUI

@main
struct DustlingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var models: AppModels

    init() {
        DustlingTheme.registerFonts()
        let models = AppModels()
        models.start()
        Appearance.apply(models.settings.appearance)
        AppDelegate.models = models
        ModalAlert.coordinator = models.quit
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
        .commands {
            // Replaces AppKit's Quit, which a window with a SwiftUI sheet refuses (QuitCoordinator).
            CommandGroup(replacing: .appTermination) {
                Button("Quit Dustling") { Task { await models.quit.requestQuit() } }
                    .keyboardShortcut("q")
            }
        }

        // First launch, limited mode's "Grant access" and Settings > Permissions open it
        // (`AppModels.openOnboarding(at:using:)`). Only the first scene opens at launch.
        Window(OnboardingWindow.title, id: OnboardingWindow.id) {
            OnboardingWindow()
                .environment(models)
        }
        .defaultSize(width: 1000, height: 660)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsWindow()
                .environment(models)
        }
    }
}
