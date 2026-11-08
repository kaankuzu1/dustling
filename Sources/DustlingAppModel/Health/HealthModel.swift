import DustlingCore
import Foundation
import Observation

/// State of the privileged cleanup helper. Only `notAvailable` is used until Plan 2 ships the helper;
/// the other cases are reserved so views can switch exhaustively already.
public enum HelperStatus: Equatable, Sendable {
    case notAvailable
    case ok
    case needsApproval
    case notResponding
}

/// What the user can do about a health light that isn't green.
public enum FixAction: Equatable, Sendable {
    case openFullDiskAccessSettings
    case viewLastRun
}

public struct HealthLight: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case fullDiskAccess, helper, lastRun }
    /// `.info` is neutral: something is not available yet, which is not a fault.
    public enum State: Equatable, Sendable { case ok, warning, info }

    public var kind: Kind
    public var state: State
    public var detail: String
    public var fix: FixAction?

    public init(kind: Kind, state: State, detail: String, fix: FixAction? = nil) {
        self.kind = kind
        self.state = state
        self.detail = detail
        self.fix = fix
    }
}

/// Full Disk Access status and the sidebar's health lights.
///
/// Time: the clock is stored as `any Clock<Duration>` (R38). Production passes `ContinuousClock()`;
/// tests pass a manual clock they advance by hand, so polling is deterministic. The probe is a
/// blocking filesystem call, so it runs off the main actor and the result is published on it.
@MainActor @Observable
public final class HealthModel {
    public private(set) var fullDiskAccess: FullDiskAccessStatus = .unknown
    /// A plain sentence when the last cleanup left items failed or needing admin; nil otherwise.
    public private(set) var lastRunProblem: String?
    public private(set) var helper: HelperStatus = .notAvailable

    @ObservationIgnored private let probe: @Sendable () -> FullDiskAccessStatus
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let lastRunSummary: @MainActor () -> RunRecord?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    public init(
        probe: @escaping @Sendable () -> FullDiskAccessStatus,
        clock: some Clock<Duration>,
        lastRunSummary: @escaping @MainActor () -> RunRecord? = { nil }
    ) {
        self.probe = probe
        self.clock = clock
        self.lastRunSummary = lastRunSummary
    }

    public var lights: [HealthLight] {
        [fullDiskAccessLight, helperLight, lastRunLight]
    }

    private var fullDiskAccessLight: HealthLight {
        switch fullDiskAccess {
        case .granted:
            return HealthLight(kind: .fullDiskAccess, state: .ok, detail: "Full Disk Access is on")
        case .denied:
            return HealthLight(
                kind: .fullDiskAccess, state: .warning,
                detail: "Full Disk Access is off, so some folders can't be scanned",
                fix: .openFullDiskAccessSettings)
        case .unknown:
            return HealthLight(
                kind: .fullDiskAccess, state: .warning,
                detail: "Couldn't verify Full Disk Access",
                fix: .openFullDiskAccessSettings)
        }
    }

    private var helperLight: HealthLight {
        switch helper {
        case .notAvailable:
            return HealthLight(
                kind: .helper, state: .info,
                detail: "Needs the cleanup helper (coming in a later version)")
        case .ok:
            return HealthLight(kind: .helper, state: .ok, detail: "The cleanup helper is running")
        case .needsApproval:
            return HealthLight(kind: .helper, state: .warning, detail: "The cleanup helper needs your approval")
        case .notResponding:
            return HealthLight(kind: .helper, state: .warning, detail: "The cleanup helper isn't responding")
        }
    }

    private var lastRunLight: HealthLight {
        if let problem = lastRunProblem {
            return HealthLight(kind: .lastRun, state: .warning, detail: problem, fix: .viewLastRun)
        }
        return HealthLight(kind: .lastRun, state: .ok, detail: "The last cleanup finished without problems")
    }

    /// Re-probes Full Disk Access (off the main actor) and re-reads the last run.
    public func refresh() async {
        let probe = self.probe
        let status = await Task.detached(priority: .userInitiated) { probe() }.value
        fullDiskAccess = status
        lastRunProblem = Self.problem(in: lastRunSummary())
    }

    /// Probes now, then every `interval` until `stopPolling()`. Used while onboarding is open so the
    /// screen flips by itself once the user grants access. Calling it again restarts the loop.
    public func startPolling(interval: Duration = .seconds(2)) {
        pollingTask?.cancel()
        let clock = self.clock
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await clock.sleep(for: interval) } catch { return }
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// The user may have changed the setting in System Settings and come back.
    public func appBecameActive() {
        Task { await refresh() }
    }

    private static func problem(in run: RunRecord?) -> String? {
        guard let run else { return nil }
        let failed = run.failedCount
        let admin = run.needsAdminCount
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed) \(failed == 1 ? "item" : "items") failed") }
        if admin > 0 { parts.append("\(admin) \(admin == 1 ? "item needs" : "items need") admin rights") }
        guard !parts.isEmpty else { return nil }
        return "The last cleanup left problems: " + parts.joined(separator: ", ")
    }
}
