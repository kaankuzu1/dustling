import AppKit
import DustlingAppModel
import SwiftUI

/// Termination for the whole app. Quit from the Dock, at logout or from AppleScript arrives as the
/// `quit` Apple Event; it takes the same route as the menu (`QuitCoordinator`), because AppKit's own
/// handler is refused while a SwiftUI sheet is attached. `applicationShouldTerminate` then asks before
/// stopping work that changes files (`TerminationPolicy`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `DustlingApp.init`, before the app finishes launching.
    @MainActor static weak var models: AppModels?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuit(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            guard let models = Self.models else {
                NSApp.terminate(nil)
                return
            }
            Task { await models.quit.requestQuit() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            switch Self.models?.termination.shouldTerminate() ?? .now {
            case .now: .terminateNow
            case .cancel: .terminateCancel
            case .later: .terminateLater
            }
        }
    }
}

/// Shows AppKit alerts and panels as sheets the quit coordinator can take down. An app-modal
/// `runModal` disables Quit until it is answered, so it is used only when no window can hold a sheet.
@MainActor
enum ModalAlert {
    /// Set by `DustlingApp.init`.
    static weak var coordinator: QuitCoordinator?

    /// The window to attach to: the main window (never a popover), unless it already has a sheet.
    private static var hostWindow: NSWindow? {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow, window.isVisible, window.attachedSheet == nil
        else { return nil }
        return window
    }

    static func show(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void = { _ in }) {
        guard let window = hostWindow else {
            completion(alert.runModal())
            return
        }
        let token = coordinator?.register { window.endSheet(alert.window, returnCode: .cancel) }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if let token { coordinator?.unregister(token) }
                completion(response)
            }
        }
    }

    static func show(_ panel: NSSavePanel, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let window = hostWindow else {
            completion(panel.runModal())
            return
        }
        let token = coordinator?.register { window.endSheet(panel, returnCode: .cancel) }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if let token { coordinator?.unregister(token) }
                completion(response)
            }
        }
    }
}

/// Registers a shown sheet or alert with the quit coordinator, so Quit can dismiss it.
private struct DismissedOnQuit: ViewModifier {
    let isShown: Bool
    let dismiss: @MainActor () -> Void

    @Environment(AppModels.self) private var models
    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onChange(of: isShown, initial: true) { _, shown in update(shown) }
            .onDisappear { update(false) }
    }

    private func update(_ shown: Bool) {
        if shown, token == nil {
            token = models.quit.register(dismiss)
        } else if !shown, let token {
            models.quit.unregister(token)
            self.token = nil
        }
    }
}

extension View {
    /// Put next to `.sheet(isPresented:)` or `.alert(isPresented:)`: Quit sets the binding to false.
    func dismissedOnQuit(_ isPresented: Binding<Bool>) -> some View {
        modifier(DismissedOnQuit(isShown: isPresented.wrappedValue, dismiss: { isPresented.wrappedValue = false }))
    }

    /// Put next to `.sheet(item:)`: Quit sets the item to nil.
    func dismissedOnQuit<Item>(_ item: Binding<Item?>) -> some View {
        modifier(DismissedOnQuit(isShown: item.wrappedValue != nil, dismiss: { item.wrappedValue = nil }))
    }
}
