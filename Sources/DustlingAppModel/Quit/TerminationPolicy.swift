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
/// current app) and the rest is waited for, at most `cap` (`systemCap` for logout, restart and
/// shutdown, under loginwindow's own timeout) as a last resort.
///
/// The question never blocks the main actor (`confirm` is async, a sheet), so a logout that
/// arrives while it is open can answer it as "quit" (`answerQuestion(quit:)`).
///
/// Every run is journaled after each item, so even a run cut off by the cap is recorded up to its
/// last item and finished off at the next launch.
@MainActor
public final class TerminationPolicy {
    private let busy: @MainActor () -> [BusyWork]
    private let confirm: @MainActor ([BusyWork]) async -> Bool
    private let stop: @MainActor () -> Void
    private let clock: any Clock<Duration>
    private let cap: Duration
    private let systemCap: Duration
    private let pollInterval: Duration
    /// The open question's answer, while it is open.
    private var pendingAnswer: CheckedContinuation<Bool, Never>?
    /// The wait's limit now; a logout during a user quit's wait shortens it to `systemCap`.
    private var currentCap: Duration

    public init(
        busy: @escaping @MainActor () -> [BusyWork],
        confirm: @escaping @MainActor ([BusyWork]) async -> Bool,
        stop: @escaping @MainActor () -> Void,
        clock: some Clock<Duration> = ContinuousClock(),
        cap: Duration = .seconds(30),
        systemCap: Duration = .seconds(20),
        pollInterval: Duration = .milliseconds(50)
    ) {
        self.busy = busy
        self.confirm = confirm
        self.stop = stop
        self.clock = clock
        self.cap = cap
        self.systemCap = systemCap
        self.pollInterval = pollInterval
        currentCap = cap
    }

    public var hasBusyWork: Bool { !busy().isEmpty }

    /// True while the question is open.
    public var isAsking: Bool { pendingAnswer != nil }

    /// The question's text and buttons for `work`.
    public static func question(for work: [BusyWork]) -> (title: String, detail: String, quit: String, keep: String) {
        let stops = work.contains { $0.stopsEarly }
        return (
            stops ? "Stop and quit?" : "Quit when it's done?",
            work.map(\.sentence).joined(separator: " "),
            stops ? "Stop and quit" : "Quit when done",
            "Keep working")
    }

    /// Answers the open question as if the user had (logout: `quit: true`). Later answers, such as
    /// the dismissed sheet's own, are ignored.
    public func answerQuestion(quit: Bool) {
        guard let answer = pendingAnswer else { return }
        pendingAnswer = nil
        answer.resume(returning: quit)
    }

    /// Logout, restart or shutdown arrived during a user quit: wait no longer than `systemCap`.
    public func hurry() {
        currentCap = min(currentCap, systemCap)
    }

    /// Readies the app to quit. False when the user chose to keep working (nothing was stopped).
    public func prepare(_ reason: QuitReason) async -> Bool {
        let work = busy()
        guard !work.isEmpty else { return true }
        if reason == .user, !(await ask(work)) { return false }
        currentCap = reason == .system ? systemCap : cap
        stop()
        var waited = Duration.zero
        while hasBusyWork && waited < currentCap {
            do { try await clock.sleep(for: pollInterval) } catch { break }
            waited += pollInterval
        }
        return true
    }

    private func ask(_ work: [BusyWork]) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingAnswer = continuation
            Task { answerQuestion(quit: await confirm(work)) }
        }
    }
}
