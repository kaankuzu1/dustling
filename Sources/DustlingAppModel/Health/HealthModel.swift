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

/// What the user can do about a health light that isn't green (SCREENS-final §8): Repair helper,
/// Open System Settings or Retry N items. Every other detail is on the Diagnostics page.
public enum FixAction: Equatable, Sendable {
    case openFullDiskAccessSettings
    /// Reserved for the helper (Plan 2). In v1 the helper is "not available yet" and has no repair.
    case repairHelper
    /// Retries the last cleanup's items that were in use or failed.
    case retryItems(count: Int)
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
    /// False until a probe result has actually been published. A probe superseded by a newer one
    /// doesn't count, so `fullDiskAccess` is never shown as a result while it is still the initial
    /// `.unknown` (Ruling R55).
    public private(set) var hasPublishedStatus = false
    /// When the last published probe finished ("Checked 2 minutes ago").
    public private(set) var lastProbeAt: Date?
    /// The newest run in the history, for the last-run light and the Diagnostics page.
    public private(set) var lastRun: RunRecord?

    @ObservationIgnored private let probe: @Sendable () -> FullDiskAccessStatus
    @ObservationIgnored private let clock: any Clock<Duration>
    /// Reads the newest run. Blocking (it reads the history), so it runs off the main actor.
    @ObservationIgnored private let lastRunSummary: @Sendable () -> RunRecord?
    /// Bumped before every last-run read, so a slow older read never overwrites a newer one.
    @ObservationIgnored private var lastRunGeneration = 0
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    /// Bumped before every probe. A probe's result is published only if no newer probe started
    /// meanwhile, so a slow older answer can never overwrite a newer one.
    @ObservationIgnored private var generation = 0

    public init(
        probe: @escaping @Sendable () -> FullDiskAccessStatus,
        clock: some Clock<Duration>,
        lastRunSummary: @escaping @Sendable () -> RunRecord? = { nil }
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
            return HealthLight(
                kind: .helper, state: .warning, detail: "The cleanup helper needs your approval", fix: .repairHelper)
        case .notResponding:
            return HealthLight(
                kind: .helper, state: .warning, detail: "The cleanup helper isn't responding", fix: .repairHelper)
        }
    }

    private var lastRunLight: HealthLight {
        if let run = lastRun, let detail = LastRunReview.summary(of: run) {
            let retry = LastRunReview.retryableCount(in: run)
            return HealthLight(
                kind: .lastRun, state: .warning, detail: detail, fix: retry > 0 ? .retryItems(count: retry) : nil)
        }
        return HealthLight(kind: .lastRun, state: .ok, detail: "The last cleanup finished without problems")
    }

    /// Re-probes Full Disk Access (off the main actor) and re-reads the last run. Returns false when a
    /// newer probe superseded this one: nothing was published, so callers must not act on the status
    /// as if it were fresh.
    @discardableResult
    public func refresh() async -> Bool {
        let probe = self.probe
        generation += 1
        let mine = generation
        let status = await Blocking.run { probe() }
        guard mine == generation else { return false }
        fullDiskAccess = status
        hasPublishedStatus = true
        lastProbeAt = Date()
        await reloadLastRun()
        return true
    }

    /// Re-reads the last run without probing, in the background. Call this when a cleanup, restore
    /// or uninstall completes so the last-run light does not wait for the next probe.
    public func refreshLastRun() {
        Task { await reloadLastRun() }
    }

    /// Re-reads the last run off the main actor and publishes it, unless a newer read started meanwhile.
    public func reloadLastRun() async {
        lastRunGeneration += 1
        let mine = lastRunGeneration
        let read = lastRunSummary
        let run = await Blocking.run { read() }
        guard mine == lastRunGeneration else { return }
        lastRun = run
        lastRunProblem = run.flatMap(LastRunReview.summary(of:)).map { "The last cleanup left problems: " + $0 }
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
        activeTask?.cancel()
        activeTask = Task { [weak self] in _ = await self?.refresh() }
    }
}
