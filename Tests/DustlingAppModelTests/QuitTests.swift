import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// Yields until `condition` holds or about two seconds pass.
@MainActor
private func soon(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Advances `clock` in `step`s until `condition` holds, so a loop sleeping on it moves forward.
@MainActor
private func advance(_ clock: ManualClock, by step: Duration, until condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        if clock.sleeperCount > 0 { clock.advance(by: step) }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// A value the test changes while a closure under test reads it.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
struct QuitCoordinatorTests {
    @Test func dismissesEveryPresentationThenTerminatesOnce() async {
        let sheets = Box(3)
        var terminated = 0
        var dismissed: [String] = []
        let clock = ManualClock()
        let quit = QuitCoordinator(
            attachedSheetCount: { sheets.value }, terminate: { terminated += 1 },
            clock: clock, timeout: .seconds(1), pollInterval: .milliseconds(20))
        for name in ["review", "emptyTrash", "blocker"] {
            quit.register { dismissed.append(name) }
        }
        #expect(quit.presentationCount == 3)

        let task = Task { await quit.requestQuit() }
        #expect(await soon { dismissed.count == 3 })
        #expect(Set(dismissed) == ["review", "emptyTrash", "blocker"])
        #expect(quit.presentationCount == 0)
        // Sheets still attached: it waits.
        #expect(await soon { clock.sleeperCount > 0 })
        #expect(terminated == 0)
        // A second Quit while waiting does nothing.
        await quit.requestQuit()
        #expect(terminated == 0)
        // The sheets go away: it terminates, once.
        sheets.value = 0
        clock.advance(by: .milliseconds(20))
        await task.value
        #expect(terminated == 1)
        #expect(!quit.isQuitting)
    }

    @Test func terminatesAtTheTimeoutWhenASheetStaysAttached() async {
        var terminated = 0
        let clock = ManualClock()
        let quit = QuitCoordinator(
            attachedSheetCount: { 1 }, terminate: { terminated += 1 },
            clock: clock, timeout: .seconds(1), pollInterval: .milliseconds(100))
        let task = Task { await quit.requestQuit() }
        #expect(await advance(clock, by: .milliseconds(100), until: { terminated > 0 }))
        await task.value
        #expect(terminated == 1)
        #expect(clock.now.offset == .seconds(1))
    }

    @Test func terminatesAtOnceWithNothingShown() async {
        var terminated = 0
        let quit = QuitCoordinator(attachedSheetCount: { 0 }, terminate: { terminated += 1 }, clock: ManualClock())
        await quit.requestQuit()
        #expect(terminated == 1)
        // Termination was cancelled (Keep working): Quit works again.
        await quit.requestQuit()
        #expect(terminated == 2)
    }

    @Test func unregisteredPresentationsAreNotDismissed() async {
        var dismissed = 0
        let quit = QuitCoordinator(attachedSheetCount: { 0 }, terminate: {}, clock: ManualClock())
        let id = quit.register { dismissed += 1 }
        quit.unregister(id)
        await quit.requestQuit()
        #expect(dismissed == 0)
    }
}

@MainActor
struct TerminationPolicyTests {
    @Test func quitsNowWhenNothingIsBusy() {
        var asked = false
        var stopped = false
        var replies: [Bool] = []
        let policy = TerminationPolicy(
            busy: { [] }, confirm: { _ in asked = true; return true }, stop: { stopped = true },
            reply: { replies.append($0) }, clock: ManualClock())
        #expect(policy.shouldTerminate() == .now)
        #expect(!asked && !stopped && replies.isEmpty)
    }

    @Test func keepWorkingCancelsAndStopsNothing() {
        var stopped = false
        var asked: [BusyWork] = []
        let policy = TerminationPolicy(
            busy: { [.cleanup] }, confirm: { asked = $0; return false }, stop: { stopped = true },
            reply: { _ in }, clock: ManualClock())
        #expect(policy.shouldTerminate() == .cancel)
        #expect(asked == [.cleanup])
        #expect(!stopped)
        #expect(!policy.isWaiting)
    }

    @Test func stopAndQuitRepliesOnceWhenTheWorkEnds() async {
        let busy = Box<[BusyWork]>([.cleanup, .emptyTrash])
        var stopped = 0
        var replies: [Bool] = []
        let clock = ManualClock()
        let policy = TerminationPolicy(
            busy: { busy.value }, confirm: { _ in true }, stop: { stopped += 1 },
            reply: { replies.append($0) }, clock: clock, timeout: .seconds(5), pollInterval: .milliseconds(50))
        #expect(policy.shouldTerminate() == .later)
        #expect(stopped == 1)
        #expect(policy.isWaiting)
        // Asked again while stopping: no second question, no second reply.
        #expect(policy.shouldTerminate() == .cancel)
        #expect(stopped == 1)
        #expect(await soon { clock.sleeperCount > 0 })
        #expect(replies.isEmpty)
        busy.value = []
        clock.advance(by: .milliseconds(50))
        #expect(await soon { !replies.isEmpty })
        #expect(replies == [true])
        #expect(!policy.isWaiting)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(replies == [true])
    }

    @Test func repliesAtTheTimeoutWhenTheWorkDoesNotEnd() async {
        var replies: [Bool] = []
        let clock = ManualClock()
        let policy = TerminationPolicy(
            busy: { [.restore] }, confirm: { _ in true }, stop: {},
            reply: { replies.append($0) }, clock: clock, timeout: .seconds(5), pollInterval: .milliseconds(500))
        #expect(policy.shouldTerminate() == .later)
        #expect(await advance(clock, by: .milliseconds(500), until: { !replies.isEmpty }))
        #expect(replies == [true])
        #expect(clock.now.offset == .seconds(5))
    }

    @Test func theQuestionSaysWhatIsRunning() {
        let text = TerminationPolicy.message(for: [.uninstall])
        #expect(text.title == "Stop and quit?")
        #expect(text.detail.hasPrefix("Dustling is uninstalling an app."))
        for work in BusyWork.allCases { #expect(work.sentence.hasSuffix(".")) }
    }
}

struct MoveProgressThrottleTests {
    final class Now: @unchecked Sendable {
        private let lock = NSLock()
        private let start = ContinuousClock.now
        private var offset = Duration.zero
        var instant: ContinuousClock.Instant { lock.withLock { start.advanced(by: offset) } }
        func advance(_ by: Duration) { lock.withLock { offset += by } }
    }

    @Test func publishesTheFirstItemThenAtMostOncePerInterval() {
        let now = Now()
        let throttle = MoveProgressThrottle(interval: .milliseconds(100), now: { now.instant })
        #expect(throttle.add(movedBytes: 10, category: .userCaches)
            == .init(items: 1, movedBytes: 10, itemsByCategory: [.userCaches: 1]))
        for _ in 0..<500 {
            #expect(throttle.add(movedBytes: 1, category: .userLogs) == nil)
        }
        now.advance(.milliseconds(100))
        let batch = throttle.add(movedBytes: 0, category: nil)
        #expect(batch == .init(items: 501, movedBytes: 500, itemsByCategory: [.userLogs: 500]))
        #expect(throttle.drain() == nil)
    }

    @Test func drainReturnsWhatIsStillCollected() {
        let now = Now()
        let throttle = MoveProgressThrottle(interval: .milliseconds(100), now: { now.instant })
        _ = throttle.add(movedBytes: 1, category: nil)
        _ = throttle.add(movedBytes: 2, category: nil)
        #expect(throttle.drain() == .init(items: 1, movedBytes: 2, itemsByCategory: [:]))
        #expect(throttle.drain() == nil)
    }
}
