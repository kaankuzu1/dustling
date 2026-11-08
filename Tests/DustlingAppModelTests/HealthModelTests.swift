import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// A deterministic clock for polling tests. `sleep` suspends until `advance(by:)` moves `now` past
/// the sleeper's deadline. Time never moves on its own.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Comparable {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [(id: UInt64, deadline: Instant, cont: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock { () -> UInt64 in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if deadline <= current {
                    lock.unlock()
                    cont.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                } else {
                    sleepers.append((id, deadline, cont))
                    lock.unlock()
                }
            }
        } onCancel: {
            let hit = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: i).cont
            }
            hit?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return ready.map(\.cont)
        }
        due.forEach { $0.resume() }
    }
}

private final class ProbeScript: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let answer: @Sendable (Int) -> FullDiskAccessStatus
    init(_ answer: @escaping @Sendable (Int) -> FullDiskAccessStatus) { self.answer = answer }
    var callCount: Int { lock.withLock { calls } }
    func probe() -> FullDiskAccessStatus {
        let n = lock.withLock { () -> Int in calls += 1; return calls }
        return answer(n)
    }
}

/// Yields until `condition` holds (the model publishes on the main actor after an off-actor probe).
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
struct HealthModelTests {
    @Test func fdaPollingFlipsToGrantedWithoutRestart() async {
        let script = ProbeScript { $0 >= 3 ? .granted : .denied }
        let clock = ManualClock()
        let model = HealthModel(probe: { script.probe() }, clock: clock)
        model.startPolling(interval: .seconds(2))
        #expect(await eventually { script.callCount == 1 && model.fullDiskAccess == .denied })

        for expected in [2, 3, 4] {
            #expect(await eventually { clock.sleeperCount == 1 })
            clock.advance(by: .seconds(2))
            #expect(await eventually { script.callCount == expected })
        }
        #expect(await eventually { model.fullDiskAccess == .granted })
        model.stopPolling()
    }

    @Test func stopPollingStopsProbing() async {
        let script = ProbeScript { _ in .denied }
        let clock = ManualClock()
        let model = HealthModel(probe: { script.probe() }, clock: clock)
        model.startPolling()
        #expect(await eventually { clock.sleeperCount == 1 })
        model.stopPolling()
        #expect(await eventually { clock.sleeperCount == 0 })
        clock.advance(by: .seconds(10))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(script.callCount == 1)
    }

    @Test func appBecameActiveReprobes() async {
        let script = ProbeScript { $0 >= 2 ? .granted : .denied }
        let model = HealthModel(probe: { script.probe() }, clock: ManualClock())
        await model.refresh()
        #expect(model.fullDiskAccess == .denied)
        model.appBecameActive()
        #expect(await eventually { model.fullDiskAccess == .granted })
        #expect(script.callCount == 2)
    }

    @Test func lostAccessTurnsLightAmber() async {
        let script = ProbeScript { $0 == 1 ? .granted : .denied }
        let model = HealthModel(probe: { script.probe() }, clock: ManualClock())
        await model.refresh()
        let ok = model.lights.first { $0.kind == .fullDiskAccess }
        #expect(ok?.state == .ok)
        #expect(ok?.fix == nil)

        await model.refresh()
        let lost = model.lights.first { $0.kind == .fullDiskAccess }
        #expect(lost?.state == .warning)
        #expect(lost?.fix == .openFullDiskAccessSettings)
    }

    /// Callers that act on the status (places, the Trash) must know whether this probe published it.
    @Test func refreshReportsWhetherItPublished() async {
        let gate = DispatchSemaphore(value: 0)
        let script = ProbeScript { n in
            if n == 1 { gate.wait(); return .granted }
            return .denied
        }
        let model = HealthModel(probe: { script.probe() }, clock: ManualClock())
        let slow = Task { await model.refresh() }
        #expect(await eventually { script.callCount == 1 })
        #expect(await model.refresh())
        gate.signal()
        #expect(await slow.value == false)
        #expect(model.fullDiskAccess == .denied)
    }

    @Test func newestProbeResultWinsOverSlowOlderOne() async {
        let gate = DispatchSemaphore(value: 0)
        let script = ProbeScript { n in
            if n == 1 { gate.wait(); return .denied }
            return .granted
        }
        let model = HealthModel(probe: { script.probe() }, clock: ManualClock())
        let slow = Task { await model.refresh() }
        #expect(await eventually { script.callCount == 1 })
        await model.refresh()
        #expect(model.fullDiskAccess == .granted)
        gate.signal()
        _ = await slow.value
        #expect(model.fullDiskAccess == .granted)
    }

    /// Ruling R55: a probe superseded by a newer one publishes nothing, so the model must not
    /// report a status as known until the newer probe has published.
    @Test func supersededProbeDoesNotCountAsPublished() async {
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        let script = ProbeScript { n in
            if n == 1 { first.wait(); return .granted }
            second.wait()
            return .denied
        }
        let model = HealthModel(probe: { script.probe() }, clock: ManualClock())
        #expect(!model.hasPublishedStatus)
        let older = Task { await model.refresh() }
        #expect(await eventually { script.callCount == 1 })
        let newer = Task { await model.refresh() }
        #expect(await eventually { script.callCount == 2 })
        first.signal()
        _ = await older.value
        #expect(!model.hasPublishedStatus)
        #expect(model.fullDiskAccess == .unknown)
        second.signal()
        _ = await newer.value
        #expect(model.hasPublishedStatus)
        #expect(model.fullDiskAccess == .denied)
    }

    /// An undecided probe is still a published result: views keyed on it check places then.
    @Test func unknownResultCountsAsPublished() async {
        let model = HealthModel(probe: { .unknown }, clock: ManualClock())
        await model.refresh()
        #expect(model.fullDiskAccess == .unknown)
        #expect(model.hasPublishedStatus)
    }

    @Test func refreshLastRunUpdatesWithoutProbing() async {
        let script = ProbeScript { _ in .granted }
        nonisolated(unsafe) var run: RunRecord?
        let model = HealthModel(probe: { script.probe() }, clock: ManualClock(), lastRunSummary: { run })
        await model.refresh()
        #expect(model.lastRunProblem == nil)
        run = RunRecord(
            startedAt: Date(), kind: .junkClean,
            entries: [JournalEntry(originalPath: "/x", bytes: 1, outcome: .failed(reason: "no"))], restorable: false)
        model.refreshLastRun()
        #expect(model.lastRunProblem != nil)
        #expect(model.lights.first { $0.kind == .lastRun }?.state == .warning)
        #expect(script.callCount == 1)
    }

    @Test func helperLightIsNeutralInfo() async {
        let model = HealthModel(probe: { .granted }, clock: ManualClock())
        let helper = model.lights.first { $0.kind == .helper }
        #expect(model.helper == .notAvailable)
        #expect(helper?.state == .info)
        #expect(helper?.detail == "Needs the cleanup helper (coming in a later version)")
        #expect(helper?.fix == nil)
    }

    @Test func lastRunWarnsWhenItemsFailedOrNeedAdmin() async {
        let bad = RunRecord(
            startedAt: Date(), kind: .junkClean,
            entries: [JournalEntry(originalPath: "/x", bytes: 1, outcome: .needsAdmin)], restorable: false)
        let model = HealthModel(probe: { .granted }, clock: ManualClock(), lastRunSummary: { bad })
        await model.refresh()
        let light = model.lights.first { $0.kind == .lastRun }
        #expect(light?.state == .warning)
        #expect(light?.fix == .viewLastRun)
        #expect(model.lastRunProblem != nil)

        let clean = HealthModel(probe: { .granted }, clock: ManualClock(), lastRunSummary: { nil })
        await clean.refresh()
        #expect(clean.lights.first { $0.kind == .lastRun }?.state == .ok)
        #expect(clean.lastRunProblem == nil)
    }
}

@MainActor
struct StorageModelTests {
    private struct Boom: Error {}

    @Test func purgeableIsClampedAtZero() async {
        let info = StorageInfo(
            totalBytes: 1000, availableForImportantUsage: 100, availableBytes: 300, localSnapshotCount: 0)
        let model = StorageModel(read: { (info, []) })
        await model.refresh()
        #expect(model.info == info)
        #expect(model.purgeableBytes == 0)
    }

    @Test func purgeableIsDifference() async {
        let info = StorageInfo(
            totalBytes: 1000, availableForImportantUsage: 500, availableBytes: 300, localSnapshotCount: 2)
        let model = StorageModel(read: { (info, ["Couldn't check Time Machine local snapshots: x"]) })
        await model.refresh()
        #expect(model.purgeableBytes == 200)
        #expect(model.problems.count == 1)
    }

    @Test func newestStorageReadWins() async {
        let gate = DispatchSemaphore(value: 0)
        let calls = ProbeScript { _ in .granted }
        let old = StorageInfo(totalBytes: 1, availableForImportantUsage: 1, availableBytes: 1, localSnapshotCount: 0)
        let new = StorageInfo(totalBytes: 2, availableForImportantUsage: 2, availableBytes: 2, localSnapshotCount: 0)
        let model = StorageModel(read: {
            if calls.probe() == .granted, calls.callCount == 1 { gate.wait(); return (old, []) }
            return (new, [])
        })
        let slow = Task { await model.refresh() }
        #expect(await eventually { calls.callCount == 1 })
        await model.refresh()
        gate.signal()
        await slow.value
        #expect(model.info == new)
    }

    @Test func failedReadReportsProblemNotZeros() async {
        let model = StorageModel(read: { throw Boom() })
        await model.refresh()
        #expect(model.info == nil)
        #expect(model.purgeableBytes == 0)
        #expect(model.problems.count == 1)
        #expect(model.problems[0].hasPrefix("Storage numbers unavailable"))
    }
}
