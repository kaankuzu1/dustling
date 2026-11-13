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
private func idlePolicy() -> TerminationPolicy {
    TerminationPolicy(busy: { [] }, confirm: { _ in true }, stop: {}, clock: ManualClock())
}

@MainActor
struct QuitCoordinatorTests {
    @Test func dismissesEveryPresentationNewestFirstThenTerminatesOnce() async {
        let sheets = Box(3)
        var terminated = 0
        var dismissed: [String] = []
        var answers: [Bool] = []
        let clock = ManualClock()
        let quit = QuitCoordinator(
            policy: idlePolicy(), attachedSheetCount: { sheets.value }, terminate: { terminated += 1 },
            clock: clock, timeout: .seconds(1), pollInterval: .milliseconds(20))
        for name in ["review", "emptyTrash", "alertOnTop"] {
            quit.register { dismissed.append(name) }
        }
        #expect(quit.presentationCount == 3)

        let task = Task { await quit.requestQuit { answers.append($0) } }
        #expect(await soon { dismissed.count == 3 })
        #expect(dismissed == ["alertOnTop", "emptyTrash", "review"])
        #expect(quit.presentationCount == 0)
        // Sheets still attached: it waits.
        #expect(await soon { clock.sleeperCount > 0 })
        #expect(terminated == 0 && answers.isEmpty)
        // A second Quit meanwhile joins this one: answered with it, never terminating on its own.
        var second: [Bool] = []
        await quit.requestQuit { second.append($0) }
        #expect(second.isEmpty && terminated == 0)
        // The sheets go away: it answers, then terminates, once.
        sheets.value = 0
        clock.advance(by: .milliseconds(20))
        #expect(await task.value)
        #expect(answers == [true])
        #expect(second == [true])
        #expect(terminated == 1)
        #expect(!quit.isQuitting)
    }

    @Test func terminatesAtTheTimeoutWhenASheetStaysAttached() async {
        var terminated = 0
        let clock = ManualClock()
        let quit = QuitCoordinator(
            policy: idlePolicy(), attachedSheetCount: { 1 }, terminate: { terminated += 1 },
            clock: clock, timeout: .seconds(1), pollInterval: .milliseconds(100))
        let task = Task { await quit.requestQuit() }
        #expect(await advance(clock, by: .milliseconds(100), until: { terminated > 0 }))
        _ = await task.value
        #expect(terminated == 1)
        #expect(clock.now.offset == .seconds(1))
    }

    @Test func terminatesAtOnceWithNothingShownAndCanQuitAgain() async {
        var terminated = 0
        let quit = QuitCoordinator(
            policy: idlePolicy(), attachedSheetCount: { 0 }, terminate: { terminated += 1 }, clock: ManualClock())
        await quit.requestQuit()
        #expect(terminated == 1)
        // Termination was cancelled somewhere: Quit works again.
        await quit.requestQuit()
        #expect(terminated == 2)
    }

    @Test func keepWorkingLeavesSheetsAloneAndAnswersFalse() async {
        var dismissed = 0
        var terminated = 0
        var stopped = 0
        var answers: [Bool] = []
        let policy = TerminationPolicy(
            busy: { [.cleanup] }, confirm: { _ in false }, stop: { stopped += 1 }, clock: ManualClock())
        let quit = QuitCoordinator(policy: policy, attachedSheetCount: { 1 }, terminate: { terminated += 1 }, clock: ManualClock())
        quit.register { dismissed += 1 }
        #expect(await quit.requestQuit { answers.append($0) } == false)
        #expect(answers == [false])
        #expect(dismissed == 0 && quit.presentationCount == 1)
        #expect(stopped == 0 && terminated == 0)
    }

    @Test func aLogoutWhileTheQuestionIsOpenAnswersItAsQuitAndAnswersBothOnce() async {
        let busy = Box<[BusyWork]>([.cleanup])
        let question = Box<CheckedContinuation<Bool, Never>?>(nil)
        var stopped = 0
        var terminated = 0
        var dismissedQuestion = 0
        var userAnswers: [Bool] = []
        var logoutAnswers: [Bool] = []
        let clock = ManualClock()
        let quit = Box<QuitCoordinator?>(nil)
        let policy = TerminationPolicy(
            busy: { busy.value },
            confirm: { _ in
                // The question sheet: registered while open, answered only by the user or a dismiss.
                await withCheckedContinuation { continuation in
                    question.value = continuation
                    quit.value?.register {
                        dismissedQuestion += 1
                        question.value?.resume(returning: false)
                        question.value = nil
                    }
                }
            },
            stop: { stopped += 1 }, clock: clock)
        let coordinator = QuitCoordinator(
            policy: policy, attachedSheetCount: { 0 }, terminate: { terminated += 1 }, clock: clock)
        quit.value = coordinator

        let user = Task { await coordinator.requestQuit(.user) { userAnswers.append($0) } }
        #expect(await soon { policy.isAsking && question.value != nil })
        // Logout arrives while the question is open: it answers it as quit and dismisses it.
        await coordinator.requestQuit(.system) { logoutAnswers.append($0) }
        #expect(dismissedQuestion == 1)
        #expect(!policy.isAsking)
        #expect(await soon { stopped == 1 })
        #expect(userAnswers.isEmpty && logoutAnswers.isEmpty && terminated == 0)
        // The work ends: both requests are answered once, then the app terminates once.
        busy.value = []
        #expect(await advance(clock, by: .milliseconds(50), until: { terminated == 1 }))
        #expect(await user.value)
        #expect(userAnswers == [true])
        #expect(logoutAnswers == [true])
        #expect(terminated == 1)
    }

    @Test func unregisteredPresentationsAreNotDismissed() async {
        var dismissed = 0
        let quit = QuitCoordinator(policy: idlePolicy(), attachedSheetCount: { 0 }, terminate: {}, clock: ManualClock())
        let id = quit.register { dismissed += 1 }
        quit.unregister(id)
        await quit.requestQuit()
        #expect(dismissed == 0)
    }

    @Test func aTerminationFromElsewhereWhileBusyGoesThroughTheQuestion() async {
        let busy = Box<[BusyWork]>([.emptyTrash])
        var asked = 0
        var terminated = 0
        let policy = TerminationPolicy(
            busy: { busy.value }, confirm: { _ in asked += 1; return false }, stop: {}, clock: ManualClock())
        let quit = QuitCoordinator(policy: policy, attachedSheetCount: { 0 }, terminate: { terminated += 1 }, clock: ManualClock())
        #expect(!quit.shouldTerminate())
        #expect(await soon { asked == 1 })
        #expect(terminated == 0)
        busy.value = []
        #expect(quit.shouldTerminate())
    }
}

@MainActor
struct TerminationPolicyTests {
    @Test func readyAtOnceWhenNothingIsBusy() async {
        var asked = false
        var stopped = false
        let policy = TerminationPolicy(
            busy: { [] }, confirm: { _ in asked = true; return true }, stop: { stopped = true }, clock: ManualClock())
        #expect(await policy.prepare(.user))
        #expect(await policy.prepare(.system))
        #expect(!asked && !stopped)
    }

    @Test func keepWorkingStopsNothing() async {
        var stopped = false
        var asked: [BusyWork] = []
        let policy = TerminationPolicy(
            busy: { [.cleanup] }, confirm: { asked = $0; return false }, stop: { stopped = true }, clock: ManualClock())
        #expect(await policy.prepare(.user) == false)
        #expect(asked == [.cleanup])
        #expect(!stopped)
    }

    @Test func aUserQuitAsksThenStopsAndWaitsForTheWorkToEnd() async {
        let busy = Box<[BusyWork]>([.cleanup, .emptyTrash])
        var asked = 0
        var stopped = 0
        var done = false
        let clock = ManualClock()
        let policy = TerminationPolicy(
            busy: { busy.value }, confirm: { _ in asked += 1; return true }, stop: { stopped += 1 },
            clock: clock, cap: .seconds(30), pollInterval: .milliseconds(50))
        let task = Task { done = await policy.prepare(.user) }
        #expect(await soon { clock.sleeperCount > 0 })
        #expect(asked == 1 && stopped == 1 && !done)
        // Well past the old 5 seconds: a cleanup is waited for until its runner returns.
        for _ in 0..<200 { clock.advance(by: .milliseconds(50)); await Task.yield() }
        #expect(!done)
        busy.value = []
        #expect(await advance(clock, by: .milliseconds(50), until: { done }))
        await task.value
        #expect(done)
    }

    @Test func logoutRestartAndShutdownNeverAsk() async {
        let busy = Box<[BusyWork]>([.uninstall])
        var asked = 0
        var stopped = 0
        let clock = ManualClock()
        let policy = TerminationPolicy(
            busy: { busy.value }, confirm: { _ in asked += 1; return false }, stop: { stopped += 1 }, clock: clock)
        var done = false
        let task = Task { done = await policy.prepare(.system) }
        #expect(await soon { stopped == 1 })
        busy.value = []
        #expect(await advance(clock, by: .milliseconds(50), until: { done }))
        await task.value
        #expect(asked == 0)
    }

    @Test func logoutWaitsAtMostTheShorterSystemCap() async {
        var done = false
        let clock = ManualClock()
        let policy = TerminationPolicy(
            busy: { [.emptyTrash] }, confirm: { _ in true }, stop: {},
            clock: clock, cap: .seconds(30), systemCap: .seconds(20), pollInterval: .milliseconds(500))
        let task = Task { done = await policy.prepare(.system) }
        #expect(await advance(clock, by: .milliseconds(500), until: { done }))
        await task.value
        #expect(clock.now.offset == .seconds(20))
    }

    @Test func givesUpAtTheCapAsALastResort() async {
        var done = false
        let clock = ManualClock()
        let policy = TerminationPolicy(
            busy: { [.restore] }, confirm: { _ in true }, stop: {},
            clock: clock, cap: .seconds(30), pollInterval: .milliseconds(500))
        let task = Task { done = await policy.prepare(.user) }
        #expect(await advance(clock, by: .milliseconds(500), until: { done }))
        await task.value
        #expect(clock.now.offset == .seconds(30))
    }

    @Test func theQuestionIsHonestAboutEachJob() {
        let cleanup = TerminationPolicy.question(for: [.cleanup, .restore])
        #expect(cleanup.title == "Stop and quit?")
        #expect(cleanup.quit == "Stop and quit")
        #expect(cleanup.keep == "Keep working")
        #expect(cleanup.detail.hasPrefix("Dustling is moving files to the Trash. It stops after the file it is on"))
        let waited = TerminationPolicy.question(for: [.emptyTrash])
        #expect(waited.title == "Quit when it's done?")
        #expect(waited.quit == "Quit when done")
        #expect(BusyWork.uninstall.sentence.contains("finishes that app"))
        for work in BusyWork.allCases where work != .cleanup {
            #expect(!work.stopsEarly)
            #expect(work.sentence.contains("finishes"))
        }
    }
}

@MainActor
struct PasswordStepTests {
    /// Holds `run` until the gate opens, as the password box holds the file work.
    private final class HeldShell: AdminShell, @unchecked Sendable {
        let gate = Gate()
        func run(script: String, prompt: String) -> AdminShellResult {
            gate.wait()
            return .cancelled
        }
    }

    @Test func aPasswordStepIsRunningOnlyWhileTheShellRuns() async throws {
        let steps = PasswordSteps()
        let held = HeldShell()
        let shell = WatchedAdminShell(held, steps: steps)
        #expect(!steps.isRunning)
        let work = Task.detached { shell.run(script: "true", prompt: "p") }
        #expect(await soon { held.gate.hasEntered })
        #expect(steps.isRunning)
        held.gate.open()
        #expect(await work.value == .cancelled)
        #expect(!steps.isRunning)
    }

    @Test func quitWaitsForThePasswordBoxAndSaysSo() {
        let work = BusyWork.passwordStep
        #expect(!work.stopsEarly)
        #expect(work.sentence == "Dustling is asking for your Mac password. It finishes once you answer or cancel "
            + "the password box; a box still open closes when Dustling quits.")
        let question = TerminationPolicy.question(for: [.cleanup, .passwordStep])
        #expect(question.title == "Stop and quit?")
        #expect(question.detail.hasSuffix(work.sentence))
    }
}

struct QuitReasonTests {
    @Test(arguments: ["logo", "rlgo", "rrst", "rest", "rsdn", "shut"])
    func logoutRestartAndShutdownAreSystemQuits(code: String) {
        #expect(QuitReason(appleEventQuitReason: QuitReason.fourCharCode(code)) == .system)
    }

    @Test func noReasonOrAnotherIsAUserQuit() {
        #expect(QuitReason(appleEventQuitReason: nil) == .user)
        #expect(QuitReason(appleEventQuitReason: QuitReason.fourCharCode("quia")) == .user)
        #expect(QuitReason.fourCharCode("logo") == 0x6C6F_676F)
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
    }
}
