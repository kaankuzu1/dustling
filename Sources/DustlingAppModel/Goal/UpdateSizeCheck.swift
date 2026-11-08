import DustlingCore
import Foundation
import Observation

/// "Check update size" next to the goal (Ruling R32): asks `softwareupdate --list` for the size of
/// the pending macOS update, only when the user clicks.
///
/// `UpdateGoal.measure` blocks (it contacts Apple) and has no timeout, so it runs on a GCD queue via
/// `Blocking.run`. Cancel returns at once: the command can't be interrupted, so its late answer is
/// dropped instead.
@MainActor @Observable
public final class UpdateSizeCheck {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        /// No macOS update is listed.
        case noUpdate
        case measured(Int64)
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Called with each measured size; the app sets its update goal from it.
    @ObservationIgnored public var onMeasured: @MainActor (Int64) -> Void = { _ in }

    @ObservationIgnored private let measure: @Sendable () throws -> Int64?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// True while a `softwareupdate` call is running, even after Cancel.
    @ObservationIgnored private var running = false
    /// False after Cancel: the running call's answer is dropped unless Start reattaches to it.
    @ObservationIgnored private var attached = false

    public init(measure: @escaping @Sendable () throws -> Int64?) {
        self.measure = measure
    }

    public convenience init(commands: CommandRunning) {
        self.init(measure: { try UpdateGoal.measure(commands: commands) })
    }

    public var isChecking: Bool { state == .checking }

    /// Starts a check. If a cancelled call is still running, this waits for that one instead of
    /// starting a second `softwareupdate`.
    public func start() {
        guard !isChecking else { return }
        state = .checking
        attached = true
        guard !running else { return }
        running = true
        let measure = self.measure
        task = Task { [self] in
            let result = await Blocking.run { Result { try measure() } }
            running = false
            guard attached else { return }
            attached = false
            switch result {
            case .success(let bytes?):
                state = .measured(bytes)
                onMeasured(bytes)
            case .success(nil):
                state = .noUpdate
            case .failure(let error):
                state = .failed(String(describing: error))
            }
        }
    }

    /// Returns at once. The command can't be interrupted; its answer is dropped.
    public func cancel() {
        guard isChecking else { return }
        attached = false
        state = .idle
    }

    /// Suspends until the check in flight (if any) has finished. For tests.
    public func awaitCheck() async {
        await task?.value
    }
}
