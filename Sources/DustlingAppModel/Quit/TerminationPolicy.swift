import Foundation

/// Why Dustling is asked to quit.
public enum QuitReason: Equatable, Sendable {
    /// The Quit menu, ⌘Q, the Dock or AppleScript: asks before stopping work.
    case user
    /// Logout, restart or shutdown: never asks (that would hold up the Mac); stops the work and waits.
    case system

    /// The quit Apple Event's `kAEQuitReason` ('why?'): logout, restart and shutdown, with or without
    /// their confirmation dialogs, are `.system`; no reason or any other is `.user`.
    public init(appleEventQuitReason code: UInt32?) {
        guard let code else { self = .user; return }
        self = Self.systemCodes.contains(code) ? .system : .user
    }

    /// kAELogOut 'logo', kAEReallyLogOut 'rlgo', kAEShowRestartDialog 'rrst', kAERestart 'rest',
    /// kAEShowShutdownDialog 'rsdn', kAEShutDown 'shut'.
    static let systemCodes: Set<UInt32> = Set(["logo", "rlgo", "rrst", "rest", "rsdn", "shut"].map(fourCharCode))

    static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Work that changes files and is running when the user quits.
public enum BusyWork: String, CaseIterable, Sendable, Hashable {
    case cleanup
    case uninstall
    case startupChange
    case retry
    case restore
    case emptyTrash

    /// True when quitting stops it early. Otherwise Dustling waits for it to finish.
    public var stopsEarly: Bool { self == .cleanup }

    /// What is running and what quitting does to it, in one or two plain sentences.
    public var sentence: String {
        switch self {
        case .cleanup:
            "Dustling is moving files to the Trash. It stops after the file it is on, and History keeps what was moved."
        case .uninstall:
            "Dustling is uninstalling an app. It finishes that app first and leaves any others alone."
        case .startupChange:
            "Dustling is changing a startup item. It finishes that change first."
        case .retry:
            "Dustling is retrying items from the last cleanup. It finishes the retry first."
        case .restore:
            "Dustling is putting files back from the Trash. It finishes putting them back first."
        case .emptyTrash:
            "Dustling is emptying the Trash. It finishes emptying it first."
        }
    }
}

/// What happens to work that changes files when Dustling quits. Nothing busy: quit at once.
/// Otherwise a user quit asks once (logout, restart and shutdown never ask); then the work is
/// stopped where it can stop (a cleanup ends after its current item, an uninstall after its
/// current app) and the rest is waited for, at most `cap` as a last resort.
///
/// Every run is journaled after each item, so even a run cut off by the cap is recorded up to its
/// last item and finished off at the next launch.
@MainActor
public final class TerminationPolicy {
    private let busy: @MainActor () -> [BusyWork]
    private let confirm: @MainActor ([BusyWork]) -> Bool
    private let stop: @MainActor () -> Void
    private let clock: any Clock<Duration>
    private let cap: Duration
    private let pollInterval: Duration

    public init(
        busy: @escaping @MainActor () -> [BusyWork],
        confirm: @escaping @MainActor ([BusyWork]) -> Bool,
        stop: @escaping @MainActor () -> Void,
        clock: some Clock<Duration> = ContinuousClock(),
        cap: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(50)
    ) {
        self.busy = busy
        self.confirm = confirm
        self.stop = stop
        self.clock = clock
        self.cap = cap
        self.pollInterval = pollInterval
    }

    public var hasBusyWork: Bool { !busy().isEmpty }

    /// The question's text and buttons for `work`.
    public static func question(for work: [BusyWork]) -> (title: String, detail: String, quit: String, keep: String) {
        let stops = work.contains { $0.stopsEarly }
        return (
            stops ? "Stop and quit?" : "Quit when it's done?",
            work.map(\.sentence).joined(separator: " "),
            stops ? "Stop and quit" : "Quit when done",
            "Keep working")
    }

    /// Readies the app to quit. False when the user chose to keep working (nothing was stopped).
    public func prepare(_ reason: QuitReason) async -> Bool {
        let work = busy()
        guard !work.isEmpty else { return true }
        if reason == .user, !confirm(work) { return false }
        stop()
        var waited = Duration.zero
        while hasBusyWork && waited < cap {
            do { try await clock.sleep(for: pollInterval) } catch { break }
            waited += pollInterval
        }
        return true
    }
}
