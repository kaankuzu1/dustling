import AppKit
import DustlingAppModel
import SwiftUI

/// Termination for the whole app. Quit from the Dock, at logout, restart or shutdown, or from
/// AppleScript arrives as the `quit` Apple Event; it takes the same route as the menu
/// (`QuitCoordinator`), because AppKit's own handler is refused while a SwiftUI sheet is attached.
/// The event is held until Dustling has decided: "Keep working" answers it with userCanceledErr
/// (-128), so the Dock or AppleScript sees the quit was cancelled.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `DustlingApp.init`, before the app finishes launching.
    @MainActor static weak var models: AppModels?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuit(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        let reason = QuitReason(appleEventQuitReason: Self.quitReason(of: event))
        MainActor.assumeIsolated {
            guard let models = Self.models else {
                NSApp.terminate(nil)
                return
            }
            let manager = NSAppleEventManager.shared()
            let suspension = manager.suspendCurrentAppleEvent()
            Task {
                await models.quit.requestQuit(reason) { quitting in
                    guard let suspension else { return }
                    if !quitting {
                        manager.replyAppleEvent(forSuspensionID: suspension)
                            .setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: keyErrorNumber)
                    }
                    manager.resume(withSuspensionID: suspension)
                }
            }
        }
    }

    /// The event's `kAEQuitReason` ('why?'), set for logout, restart and shutdown.
    private static func quitReason(of event: NSAppleEventDescriptor) -> UInt32? {
        let keyword = AEKeyword(kAEQuitReason)
        guard let descriptor = event.attributeDescriptor(forKeyword: keyword) ?? event.paramDescriptor(forKeyword: keyword)
        else { return nil }
        return descriptor.enumCodeValue
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            (Self.models?.quit.shouldTerminate() ?? true) ? .terminateNow : .terminateCancel
        }
    }
}

/// Shows AppKit alerts and panels as sheets the quit coordinator can take down. An app-modal
/// `runModal` disables Quit until it is answered, so it is used only when no window can hold a sheet.
@MainActor
enum ModalAlert {
    /// Set by `DustlingApp.init`.
    static weak var coordinator: QuitCoordinator?

    /// The window to attach to: the main window (never a popover), or the sheet on top of it, so
    /// the alert never falls back to an app-modal `runModal` that would disable Quit.
    private static var hostWindow: NSWindow? {
        guard var window = NSApp.mainWindow ?? NSApp.keyWindow, window.isVisible else { return nil }
        while let sheet = window.attachedSheet { window = sheet }
        return window
    }

    /// Shows `alert` as a sheet on the main window (or the sheet on top of it); with no window, as
    /// a free-standing window. Never `runModal`, so it never blocks the main actor or disables Quit.
    /// `escape`: the response Escape gives (NSAlert gives Escape only to a button titled Cancel).
    static func show(
        _ alert: NSAlert, escape: NSApplication.ModalResponse? = nil,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void = { _ in }
    ) {
        var end: (NSApplication.ModalResponse) -> Void = { _ in }
        var token: UUID?
        var monitor: Any?
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if let token { coordinator?.unregister(token) }
            if let monitor { NSEvent.removeMonitor(monitor) }
            token = nil
            monitor = nil
            completion(response)
        }
        if let window = hostWindow {
            end = { window.endSheet(alert.window, returnCode: $0) }
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
        } else {
            let free = FreeStandingAlert(alert) { response in finish(response) }
            end = { free.finish($0) }
            free.show()
        }
        token = coordinator?.register { end(.cancel) }
        if let escape {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, event.window === alert.window else { return event }
                end(escape)
                return nil
            }
        }
    }

    /// Asks with `alert` (see `show`) and returns the button's response.
    static func ask(_ alert: NSAlert, escape: NSApplication.ModalResponse? = nil) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            show(alert, escape: escape) { continuation.resume(returning: $0) }
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

/// An NSAlert in its own window, not app-modal: its buttons answer through `finish`, like a sheet's.
@MainActor
private final class FreeStandingAlert: NSObject {
    /// Shown alerts, kept alive until answered.
    private static var shown: Set<FreeStandingAlert> = []
    private let alert: NSAlert
    private var completion: ((NSApplication.ModalResponse) -> Void)?

    init(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.completion = completion
        super.init()
    }

    func show() {
        if alert.buttons.isEmpty { alert.addButton(withTitle: "OK") }
        for (index, button) in alert.buttons.enumerated() {
            button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
            button.target = self
            button.action = #selector(pressed(_:))
        }
        alert.layout()
        Self.shown.insert(self)
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func pressed(_ button: NSButton) {
        finish(NSApplication.ModalResponse(rawValue: button.tag))
    }

    func finish(_ response: NSApplication.ModalResponse) {
        guard let completion else { return }
        self.completion = nil
        alert.window.orderOut(nil)
        Self.shown.remove(self)
        completion(response)
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
