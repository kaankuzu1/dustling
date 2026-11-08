import Foundation

/// Makes Quit work whatever is on screen.
///
/// A SwiftUI window with a sheet attached refuses to terminate, before the app delegate is even
/// asked, and `NSWindow.endSheet` can't take a SwiftUI sheet down. So every sheet and alert registers
/// how to dismiss itself while it is shown, and Quit (the menu, ⌘Q, the Dock, logout, AppleScript)
/// goes through `requestQuit()`: it dismisses them all, waits until no window has a sheet attached
/// (at most `timeout`), then terminates exactly once.
@MainActor
public final class QuitCoordinator {
    public typealias Dismiss = @MainActor () -> Void

    private var presentations: [UUID: Dismiss] = [:]
    private let attachedSheetCount: @MainActor () -> Int
    private let terminate: @MainActor () -> Void
    private let clock: any Clock<Duration>
    private let timeout: Duration
    private let pollInterval: Duration
    /// True from `requestQuit()` until it has called `terminate`. A second request meanwhile is ignored.
    public private(set) var isQuitting = false

    public init(
        attachedSheetCount: @escaping @MainActor () -> Int,
        terminate: @escaping @MainActor () -> Void,
        clock: some Clock<Duration> = ContinuousClock(),
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(20)
    ) {
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
        presentations[id] = dismiss
        return id
    }

    /// Call when it is gone. Unknown ids are ignored.
    public func unregister(_ id: UUID) {
        presentations[id] = nil
    }

    /// Dismisses every registered sheet and alert.
    public func dismissAll() {
        let all = presentations.values
        presentations.removeAll()
        for dismiss in all { dismiss() }
    }

    /// Dismisses everything, waits until no sheet is attached or `timeout` passes, then terminates.
    /// If termination is then cancelled (the user chose to keep working), Quit can be asked again.
    public func requestQuit() async {
        guard !isQuitting else { return }
        isQuitting = true
        defer { isQuitting = false }
        dismissAll()
        var waited = Duration.zero
        while attachedSheetCount() > 0 && waited < timeout {
            do { try await clock.sleep(for: pollInterval) } catch { break }
            waited += pollInterval
        }
        terminate()
    }
}
