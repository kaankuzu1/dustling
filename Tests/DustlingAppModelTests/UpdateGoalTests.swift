import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

private struct FakeRunner: CommandRunning {
    var result: Result<CommandResult, Error>
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        #expect(executable == "/usr/sbin/softwareupdate")
        #expect(arguments == ["--list"])
        return try result.get()
    }
}

private struct Boom: Error {}

struct UpdateGoalTests {
    let sample = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: Safari18.1
        \tTitle: Safari, Version: 18.1, Size: 150000KiB, Recommended: YES,
        * Label: macOS Tahoe 26.2-25C56
        \tTitle: macOS Tahoe 26.2, Version: 26.2, Size: 7123456KiB, Recommended: YES, Action: restart,
        * Label: macOS Tahoe 26.1-25B1
        \tTitle: macOS Tahoe 26.1, Version: 26.1, Size: 6000000KiB, Recommended: NO, Action: restart,
        """

    @Test func parsesSoftwareupdateSize() throws {
        let runner = FakeRunner(result: .success(CommandResult(status: 0, stdout: sample, stderr: "")))
        #expect(try UpdateGoal.measure(commands: runner) == 7_123_456 * 1024)
    }

    @Test func noMacOSEntryReturnsNil() throws {
        let text = "\tTitle: Safari, Version: 18.1, Size: 150000KiB, Recommended: YES,\n"
        let runner = FakeRunner(result: .success(CommandResult(status: 0, stdout: text, stderr: "")))
        #expect(try UpdateGoal.measure(commands: runner) == nil)
    }

    @Test func unreadableMacOSSizeThrowsInsteadOfNil() {
        for line in [
            "\tTitle: macOS Tahoe 26.2, Version: 26.2, Size: 7123456K, Recommended: YES,\n",
            "\tTitle: macOS Tahoe 26.2, Version: 26.2, Recommended: YES,\n",
        ] {
            let runner = FakeRunner(result: .success(CommandResult(status: 0, stdout: line, stderr: "")))
            #expect(throws: (any Error).self) { try UpdateGoal.measure(commands: runner) }
        }
    }

    @Test func nonZeroExitThrows() {
        let runner = FakeRunner(result: .success(CommandResult(status: 1, stdout: "", stderr: "boom")))
        #expect(throws: (any Error).self) { try UpdateGoal.measure(commands: runner) }
    }

    @Test func launchFailureThrows() {
        let runner = FakeRunner(result: .failure(Boom()))
        #expect(throws: (any Error).self) { try UpdateGoal.measure(commands: runner) }
    }

    @Test func defaultIsThirtyGigabytesUserSet() {
        let goal = UpdateGoal()
        #expect(goal.neededBytes == 30_000_000_000)
        #expect(goal.source == .userSet)
    }

    @Test func shortfallNeverNegative() {
        let goal = UpdateGoal(neededBytes: 30_000_000_000, source: .userSet)
        #expect(goal.shortfall(available: 10_000_000_000) == 20_000_000_000)
        #expect(goal.shortfall(available: 50_000_000_000) == 0)
    }

    @Test func codableRoundTrip() throws {
        let goal = UpdateGoal(neededBytes: 5, source: .measured(Date(timeIntervalSince1970: 100)))
        let data = try JSONEncoder().encode(goal)
        #expect(try JSONDecoder().decode(UpdateGoal.self, from: data) == goal)
    }
}
