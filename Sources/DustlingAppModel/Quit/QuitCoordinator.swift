import Foundation

/// Makes Quit work whatever is on screen and whatever is running.
///
/// A SwiftUI window with a sheet attached refuses to terminate, before the app delegate is even
/// asked, and `NSWindow.endSheet` can't take a SwiftUI sheet down. So every sheet and alert registers
/// how to dismiss itself while it is shown, and every quit (the menu, ⌘Q, the Dock, logout,
/// AppleScript) goes through `requestQuit(_:answer:)`: first the busy question and stopping the
/// work (`TerminationPolicy`), so "Keep working" leaves everything as it was; then it dismisses every
/// sheet, waits until none is attached (at most `timeout`), and terminates exactly once.
@MainActor
public final class QuitCoordinator {
    public typealias Dismiss = @MainActor () -> Void

    /// In the order shown; dismissed newest first, so an alert on a sheet goes before the sheet.
    private var presentations: [(id: UUID, dismiss: Dismiss)] = []
    private let policy: TerminationPolicy
    private let attachedSheetCount: @MainActor () -> Int
    private let terminate: @MainActor () -> Void
    private let clock: any Clock<Duration>
    private let timeout: Duration
    private let pollInterval: Duration
    /// True from `requestQuit` until it has finished. A second request meanwhile is answered at once.
    public private(set) var isQuitting = false
    /// True only while `terminate` runs, so `shouldTerminate()` lets that termination through.
    private var isTerminating = false

    public init(
        policy: TerminationPolicy,
        attachedSheetCount: @escaping @MainActor () -> Int,
        terminate: @escaping @MainActor () -> Void,
        clock: some Clock<Duration> = ContinuousClock(),
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(20)
    ) {
        self.policy = policy
        self.attachedSheetCount = attachedSheetCount
        self.terminate = terminate
        self.clock = clock
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    /// The sheets and alerts shown right now.
    public var presentationCount: Int { presentations.count }

    /// Call when a sheet or alert appears. `dismiss` takes it down (sets its binding to false or nil).
    @discardableResult
    public func register(_ dismiss: @escaping Dismiss) -> UUID {
        let id = UUID()
        presentations.append((id, dismiss))
        return id
    }

    /// Call when it is gone. Unknown ids are ignored.
    public func unregister(_ id: UUID) {
        presentations.removeAll { $0.id == id }
    }

    /// Dismisses every registered sheet and alert, newest first.
    public func dismissAll() {
        let all = presentations.reversed().map(\.dismiss)
        presentations.removeAll()
        for dismiss in all { dismiss() }
    }

    /// Quits: asks about running work (`.user` only) and stops it, dismisses everything, waits until
    /// no sheet is attached or `timeout` passes, then terminates. `answer` is called exactly once:
    /// false when the user keeps working, true right before terminating (or at once when a quit is
    /// already under way). Returns the same value.
    @discardableResult
    public func requestQuit(_ reason: QuitReason = .user, answer: @MainActor (Bool) -> Void = { _ in }) async -> Bool {
        guard !isQuitting else {
            answer(true)
            return true
        }
        isQuitting = true
        defer { isQuitting = false }
        guard await policy.prepare(reason) else {
            answer(false)
            return false
        }
        dismissAll()
        var waited = Duration.zero
        while attachedSheetCount() > 0 && waited < timeout {
            do { try await clock.sleep(for: pollInterval) } catch { break }
            waited += pollInterval
        }
        answer(true)
        isTerminating = true
        defer { isTerminating = false }
        terminate()
        return true
    }

    /// `applicationShouldTerminate`: true lets termination happen now. A termination that didn't
    /// come through `requestQuit` while work is running is refused and sent through it instead.
    public func shouldTerminate() -> Bool {
        if isTerminating || !policy.hasBusyWork { return true }
        if !isQuitting { Task { await requestQuit(.user) } }
        return false
    }
}
