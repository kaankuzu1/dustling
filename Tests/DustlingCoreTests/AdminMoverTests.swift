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
            trash.appending(path: "a 3.log").path(percentEncoded: false) + "/",
        ]
        #expect(path(mover.trashDestination(for: item, taken: taken)) == path(trash.appending(path: "a 4.log")))
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

    // MARK: - Folders and items swapped between planning and running

    private let refused = AdminStepResult.notDone(reason: "macOS refused, even with your password")

    private func size(_ url: URL) -> Int64 {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0 ? Int64(st.st_size) : -1
    }

    private func contents(_ url: URL) -> [String] {
        (try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
    }

    private func moveStep(_ from: URL, _ to: URL, expected: ItemIdentity? = nil) -> AdminStep {
        AdminStep(op: .move(from: from, to: to, bootOutDaemon: false), expectedSource: expected)
    }

    @Test func trashSwappedForALinkIsRefused() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let elsewhere = try sandbox.directory("elsewhere")
        let item = try sandbox.file("Library/Caches/a", bytes: 4)
        let destination = try #require(
            AdminMover(shell: CannedShell(), environment: sandbox.environment).trashDestination(for: item))
        let realTrash = sandbox.root.appending(path: "home/Trash-real")
        let shell = UserShell(beforeRun: {
            try FileManager.default.moveItem(at: trash, to: realTrash)
            try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: elsewhere)
        })
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        #expect(mover.perform([moveStep(item, destination)], prompt: "p") == [refused])
        #expect(size(item) == 4)
        #expect(contents(elsewhere).isEmpty)
        #expect(contents(realTrash).isEmpty)
    }

    @Test func destinationTakenByALinkIsNeverFollowed() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let elsewhere = try sandbox.directory("elsewhere")
        let item = try sandbox.directory("Library/Caches/com.x")
        try sandbox.file("Library/Caches/com.x/data", bytes: 4)
        let destination = trash.appending(path: "com.x")
        let shell = UserShell(beforeRun: {
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: elsewhere)
        })
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        #expect(mover.perform([moveStep(item, destination)], prompt: "p")
            == [.notDone(reason: "something with the same name is already there")])
        #expect(size(item.appending(path: "data")) == 4)
        #expect(contents(elsewhere).isEmpty)
    }

    @Test func folderThatIsALinkWhenPlannedIsRefused() throws {
        let sandbox = try TestSandbox()
        let elsewhere = try sandbox.directory("elsewhere")
        try fm.createSymbolicLink(at: sandbox.environment.userTrash, withDestinationURL: elsewhere)
        let item = try sandbox.file("Library/Caches/a", bytes: 4)
        let shell = UserShell()
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        #expect(mover.perform([moveStep(item, sandbox.environment.userTrash.appending(path: "a"))], prompt: "p")
            == [refused])
        #expect(shell.calls.first?.script.hasSuffix("\nreport_ 0 err\nexit 0\n") == true)
        #expect(size(item) == 4)
        #expect(contents(elsewhere).isEmpty)
    }

    @Test func deleteFolderSwappedForALinkIsRefused() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.file("home/.Trash/Extensions/mine.kext", bytes: 4)
        let system = try sandbox.file("Library/Extensions/system.kext", bytes: 5)
        let realTrash = sandbox.root.appending(path: "home/Trash-real")
        let library = sandbox.environment.systemLibrary
        let shell = UserShell(beforeRun: {
            try FileManager.default.moveItem(at: trash, to: realTrash)
            try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: library)
        })
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        #expect(mover.perform([AdminStep(op: .delete(trash.appending(path: "Extensions")))], prompt: "p")
            == [refused])
        #expect(size(system) == 5)
        #expect(size(realTrash.appending(path: "Extensions/mine.kext")) == 4)
    }

    @Test func deleteWhoseFolderWasReplacedIsRefused() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.file("home/.Trash/y", bytes: 4)
        let oldTrash = sandbox.root.appending(path: "home/Trash-old")
        let shell = UserShell(beforeRun: {
            try FileManager.default.moveItem(at: trash, to: oldTrash)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            try Data(count: 6).write(to: trash.appending(path: "y"))
        })
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        #expect(mover.perform([AdminStep(op: .delete(trash.appending(path: "y")))], prompt: "p") == [refused])
        #expect(size(trash.appending(path: "y")) == 6)
        #expect(size(oldTrash.appending(path: "y")) == 4)
    }

    /// Replaces the file at `url` with a new one (a different inode) of `bytes` bytes.
    private static func swap(_ url: URL, bytes: Int) throws {
        let fresh = url.deletingLastPathComponent().appending(path: "fresh-\(UUID().uuidString)")
        try Data(count: bytes).write(to: fresh)
        _ = rename(fresh.path(percentEncoded: false), url.path(percentEncoded: false))
    }

    @Test func putBackOfASwappedItemIsRefused() throws {
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/com.x.plist", bytes: 4)
        try sandbox.directory("Library/LaunchDaemons")
        let original = sandbox.root.appending(path: "Library/LaunchDaemons/com.x.plist")
        let recorded = try #require(ItemIdentity.of(trashed))
        let shell = UserShell(beforeRun: { try Self.swap(trashed, bytes: 7) })
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        #expect(mover.perform([moveStep(trashed, original, expected: recorded)], prompt: "p") == [refused])
        #expect(size(trashed) == 7)
        #expect(ItemIdentity.of(trashed) != recorded)
        #expect(size(original) == -1)
    }

    @Test func putBackOfTheRecordedItemMoves() throws {
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/com.x.plist", bytes: 4)
        try sandbox.directory("Library/LaunchDaemons")
        let original = sandbox.root.appending(path: "Library/LaunchDaemons/com.x.plist")
        let recorded = try #require(ItemIdentity.of(trashed))
        let mover = AdminMover(shell: UserShell(), environment: sandbox.environment)
        #expect(mover.perform([moveStep(trashed, original, expected: recorded)], prompt: "p") == [.done])
        #expect(ItemIdentity.of(original) == recorded)
        #expect(size(trashed) == -1)
    }

    @Test func deleteChecksTheRecordedItem() throws {
        let sandbox = try TestSandbox()
        let swapped = try sandbox.file("home/.Trash/a", bytes: 4)
        let kept = try sandbox.file("home/.Trash/b", bytes: 4)
        let recordedA = try #require(ItemIdentity.of(swapped))
        let recordedB = try #require(ItemIdentity.of(kept))
        let shell = UserShell(beforeRun: { try Self.swap(swapped, bytes: 9) })
        let mover = AdminMover(shell: shell, environment: sandbox.environment)
        let results = mover.perform([
            AdminStep(op: .delete(swapped), expectedSource: recordedA),
            AdminStep(op: .delete(kept), expectedSource: recordedB),
        ], prompt: "p")
        #expect(results == [refused, .done])
        #expect(size(swapped) == 9)
        #expect(size(kept) == -1)
    }

    @Test func identityIsReadWithoutFollowingLinks() throws {
        let sandbox = try TestSandbox()
        let target = try sandbox.directory("target")
        let link = sandbox.root.appending(path: "link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let linkIdentity = try #require(ItemIdentity.of(link))
        #expect(linkIdentity != ItemIdentity.of(target))
        #expect(ItemIdentity.of(URL(filePath: link.path(percentEncoded: false) + "/")) == linkIdentity)
        #expect(linkIdentity.owner == getuid())
        #expect(ItemIdentity.of(sandbox.root.appending(path: "missing")) == nil)
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
