import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

@MainActor
struct UpdateSizeCheckTests {
    private struct Boom: Error, CustomStringConvertible { var description: String { "no network" } }

    @Test func measuredSizeIsPublishedAndHandedOn() async {
        var handed: Int64?
        let check = UpdateSizeCheck(measure: { 7_000_000_000 })
        check.onMeasured = { handed = $0 }
        check.start()
        #expect(check.state == .checking)
        await check.awaitCheck()
        #expect(check.state == .measured(7_000_000_000))
        #expect(handed == 7_000_000_000)
    }

    @Test func noPendingUpdateIsSaidPlainly() async {
        let check = UpdateSizeCheck(measure: { nil })
        check.start()
        await check.awaitCheck()
        #expect(check.state == .noUpdate)
    }

    @Test func failureKeepsTheReason() async {
        let check = UpdateSizeCheck(measure: { throw Boom() })
        check.start()
        await check.awaitCheck()
        #expect(check.state == .failed("no network"))
    }

    @Test func cancelReturnsAtOnceAndDropsTheLateAnswer() async {
        let gate = Gate()
        var handed: Int64?
        let check = UpdateSizeCheck(measure: { gate.wait(); return 9 })
        check.onMeasured = { handed = $0 }
        check.start()
        #expect(await waitUntil { gate.hasEntered })
        check.cancel()
        #expect(check.state == .idle)
        gate.open()
        await check.awaitCheck()
        #expect(check.state == .idle)
        #expect(handed == nil)
    }

    @Test func secondStartWhileCheckingIsIgnored() async {
        let gate = Gate()
        var calls = 0
        let check = UpdateSizeCheck(measure: { gate.wait(); return 1 })
        check.onMeasured = { _ in calls += 1 }
        check.start()
        check.start()
        gate.open()
        await check.awaitCheck()
        #expect(calls == 1)
    }
}
