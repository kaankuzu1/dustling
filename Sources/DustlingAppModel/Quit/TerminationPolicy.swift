import Foundation

/// Work that changes files and is running when the user quits.
public enum BusyWork: String, CaseIterable, Sendable, Hashable {
    case cleanup
    case uninstall
    case startupChange
    case retry
    case restore
    case emptyTrash

    /// One plain sentence saying what is running.
    public var sentence: String {
        switch self {
        case .cleanup: "Dustling is moving files to the Trash."
        case .uninstall: "Dustling is uninstalling an app."
        case .startupChange: "Dustling is changing a startup item."
        case .retry: "Dustling is retrying items from the last cleanup."
        case .restore: "Dustling is putting files back from the Trash."
        case .emptyTrash: "Dustling is emptying the Trash."
        }
    }
}

/// The app delegate's `applicationShouldTerminate`: quits at once when nothing that changes files is
/// running; otherwise asks once ("Stop and quit?"), stops the work and answers later, when the work
/// has ended or after `timeout`, whichever comes first. It answers exactly once per quit.
///
/// Every run is journaled after each item, so a run cut off by the timeout is still recorded up to
/// its last item and finished off at the next launch.
@MainActor
public final class TerminationPolicy {
    public enum Decision: Equatable, Sendable {
        /// Nothing is busy: quit now.
        case now
        /// The user chose to keep working.
        case cancel
        /// Work is stopping; `reply(true)` follows.
        case later
    }

    private let busy: @MainActor () -> [BusyWork]
    private let confirm: @MainActor ([BusyWork]) -> Bool
    private let stop: @MainActor () -> Void
    private let reply: @MainActor (Bool) -> Void
    private let clock: any Clock<Duration>
    private let timeout: Duration
    private let pollInterval: Duration
    /// True between answering `.later` and calling `reply`.
    public private(set) var isWaiting = false

    public init(
        busy: @escaping @MainActor () -> [BusyWork],
        confirm: @escaping @MainActor ([BusyWork]) -> Bool,
        stop: @escaping @MainActor () -> Void,
        reply: @escaping @MainActor (Bool) -> Void,
        clock: some Clock<Duration> = ContinuousClock(),
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(50)
    ) {
        self.busy = busy
        self.confirm = confirm
        self.stop = stop
        self.reply = reply
        self.clock = clock
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    /// The question's text: "Stop and quit?" and what is running.
    public static func message(for work: [BusyWork]) -> (title: String, detail: String) {
        let running = work.map(\.sentence).joined(separator: " ")
        return ("Stop and quit?", running + " If you quit now, it stops after the current item and History keeps what was done.")
    }

    public func shouldTerminate() -> Decision {
        // Already stopping for an earlier quit: that one's reply ends the app.
        guard !isWaiting else { return .cancel }
        let work = busy()
        guard !work.isEmpty else { return .now }
        guard confirm(work) else { return .cancel }
        stop()
        isWaiting = true
        Task { await waitThenReply() }
        return .later
    }

    private func waitThenReply() async {
        var waited = Duration.zero
        while !busy().isEmpty && waited < timeout {
            do { try await clock.sleep(for: pollInterval) } catch { break }
            waited += pollInterval
        }
        isWaiting = false
        reply(true)
    }
}
