import Foundation
import Testing
@testable import DustlingCore

/// Only fake shells here: `UserShell` runs the script as the current user inside a `TestSandbox`,
/// `CannedShell` runs nothing. No password box can appear.
struct AdminMoverTests {
    private let fm = FileManager.default

    private func path(_ url: URL?) -> String? {
        url?.path(percentEncoded: false)
    }

    @Test func trashDestinationKeepsTheNameWhenItIsFree() throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let item = try sandbox.file("Library/Caches/a.log")
        let mover = AdminMover(shell: CannedShell(), environment: sandbox.environment)
        #expect(path(mover.trashDestination(for: item))
            == path(sandbox.environment.userTrash.appending(path: "a.log")))
    }

    @Test func trashDestinationAddsNumberBeforeExtension() throws {
        let sandbox = try TestSandbox()
        let trash = sandbox.environment.userTrash
        try sandbox.file("home/.Trash/Report.pdf")
        try sandbox.file("home/.Trash/Report 2.pdf")
        try sandbox.directory("home/.Trash/com.apple.foo")
        try sandbox.directory("home/.Trash/Tool.app")
        try fm.createSymbolicLink(
            atPath: trash.appending(path: "x.log").path(percentEncoded: false), withDestinationPath: "/nonexistent")
        let mover = AdminMover(shell: CannedShell(), environment: sandbox.environment)

        let report = try sandbox.file("Library/Report.pdf")
        #expect(path(mover.trashDestination(for: report)) == path(trash.appending(path: "Report 3.pdf")))
        // A folder whose name has dots keeps them: the number goes at the end.
        let folder = try sandbox.directory("Library/Caches/com.apple.foo")
        #expect(path(mover.trashDestination(for: folder)) == path(trash.appending(path: "com.apple.foo 2")))
        // An app looks like a file in Finder, so it keeps its extension.
        let app = try sandbox.app("Applications/Tool.app", bundleID: "com.example.tool")
        #expect(path(mover.trashDestination(for: app)) == path(trash.appending(path: "Tool 2.app")))
        // A dangling link in the Trash still takes the name (lstat).
        let log = try sandbox.file("Library/Logs/x.log")
        #expect(path(mover.trashDestination(for: log)) == path(trash.appending(path: "x 2.log")))
    }

    @Test func trashDestinationSkipsTaken() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let item = try sandbox.file("Library/Caches/a.log")
        let mover = AdminMover(shell: CannedShell(), environment: sandbox.environment)
        let taken: Set<String> = [
            trash.appending(path: "a.log").path(percentEncoded: false),
            trash.appending(path: "A 2.LOG").path(percentEncoded: false),
        ]
        #expect(path(mover.trashDestination(for: item, taken: taken)) == path(trash.appending(path: "a 3.log")))
    }

    @Test func trashDestinationIsNilOnAnotherVolume() throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let mover = AdminMover(shell: CannedShell(), environment: sandbox.environment)
        // /dev is its own file system, so it can't be renamed into the Trash.
        #expect(mover.trashDestination(for: URL(filePath: "/dev/null")) == nil)
        #expect(mover.trashDestination(for: sandbox.root.appending(path: "Library/missing")) == nil)
    }

    @Test func performMovesWithOneScriptAndThePrompt() throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let a = try sandbox.file("Library/Caches/a", bytes: 2)
        let b = try sandbox.file("Library/Caches/b", bytes: 2)
        let shell = UserShell()
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        let prompt = AdminMover.movePrompt(count: 2)
        let steps = try [a, b].map { url in
            AdminStep(op: .move(from: url, to: try #require(mover.trashDestination(for: url)), bootOutDaemon: false),
                      dependsOn: nil)
        }
        #expect(mover.perform(steps, prompt: prompt) == [.done, .done])
        #expect(shell.calls.count == 1)
        #expect(shell.calls.first?.prompt == prompt)
        #expect(fm.fileExists(atPath: sandbox.environment.userTrash.appending(path: "b").path(percentEncoded: false)))
    }

    @Test func cancelledShellCancelsEveryStep() throws {
        let sandbox = try TestSandbox()
        let item = try sandbox.file("Library/Caches/a", bytes: 2)
        let shell = CannedShell(.cancelled)
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        let steps = [
            AdminStep(op: .move(from: item, to: sandbox.environment.userTrash.appending(path: "a"),
                                bootOutDaemon: false), dependsOn: nil),
            AdminStep(op: .delete(sandbox.environment.userTrash.appending(path: "b")), dependsOn: 0),
        ]
        #expect(mover.perform(steps, prompt: "p") == [.cancelled, .cancelled])
        #expect(shell.calls.count == 1)
        #expect(fm.fileExists(atPath: item.path(percentEncoded: false)))
    }

    @Test func failedShellReportsEveryStepNotDone() throws {
        let sandbox = try TestSandbox()
        let mover = AdminMover(shell: CannedShell(.failed(reason: "osascript broke")), environment: sandbox.environment)
        let steps = [
            AdminStep(op: .delete(sandbox.environment.userTrash.appending(path: "a")), dependsOn: nil),
            AdminStep(op: .delete(sandbox.environment.userTrash.appending(path: "b")), dependsOn: nil),
        ]
        #expect(mover.perform(steps, prompt: "p")
            == [.notDone(reason: "osascript broke"), .notDone(reason: "osascript broke")])
    }

    @Test func emptyStepsNeverCallShell() throws {
        let sandbox = try TestSandbox()
        let shell = CannedShell(.finished(output: ""))
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        #expect(mover.perform([], prompt: "p") == [])
        #expect(shell.calls.isEmpty)
    }

    @Test func promptsAreExact() {
        #expect(AdminMover.movePrompt(count: 1)
            == "Dustling needs your password to move 1 item that belongs to the system to the Trash.")
        #expect(AdminMover.movePrompt(count: 3)
            == "Dustling needs your password to move 3 items that belong to the system to the Trash.")
        #expect(AdminMover.deletePrompt(count: 1)
            == "Dustling needs your password to delete 1 item in the Trash that belongs to the system.")
        #expect(AdminMover.deletePrompt(count: 2)
            == "Dustling needs your password to delete 2 items in the Trash that belong to the system.")
        #expect(AdminMover.restorePrompt(count: 1)
            == "Dustling needs your password to put back 1 item into a system folder.")
        #expect(AdminMover.restorePrompt(count: 4)
            == "Dustling needs your password to put back 4 items into system folders.")
    }
}
