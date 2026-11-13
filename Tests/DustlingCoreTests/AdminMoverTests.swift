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
        let mover = AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning())
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
    private let unsafe = AdminStepResult.notDone(
        reason: "Dustling can't safely move this with your password. Move it to the Trash in Finder.")

    private func size(_ url: URL) -> Int64 {
        var st = stat()
        return lstat(AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false)), &st) == 0
            ? Int64(st.st_size) : -1
    }

    private func contents(_ url: URL) -> [String] {
        (try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
    }

    private func moveStep(_ from: URL, _ to: URL, expected: ItemIdentity? = nil) -> AdminStep {
        AdminStep(op: .move(from: from, to: to, bootOutDaemon: false), expectedSource: expected)
    }

    /// A mover whose bridge is made in the sandbox and owned by the user running the test (a test
    /// can't make root-owned folders); `locked` folders count as ones the user can't write.
    private func mover(
        _ shell: any AdminShell, _ sandbox: TestSandbox, locked: @escaping @Sendable (String) -> Bool = { _ in false }
    ) throws -> AdminMover {
        AdminMover(shell: shell, environment: sandbox.environment, planning: try sandbox.adminPlanning(locked: locked))
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
        #expect(try mover(shell, sandbox).perform([moveStep(item, destination)], prompt: "p") == [refused])
        #expect(shell.calls.first?.script.contains("\nmove_ 0 ") == true)
        #expect(size(item) == 4)
        #expect(contents(elsewhere).isEmpty)
        #expect(contents(realTrash).isEmpty)
        #expect(contents(sandbox.bridges).isEmpty)
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
        #expect(try mover(shell, sandbox).perform([moveStep(item, destination)], prompt: "p")
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
        #expect(try mover(shell, sandbox).perform(
            [moveStep(item, sandbox.environment.userTrash.appending(path: "a"))], prompt: "p") == [unsafe])
        #expect(shell.calls.first?.script.hasSuffix("\nreport_ 0 unsafe\nexit 0\n") == true)
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
        #expect(try mover(shell, sandbox).perform([AdminStep(op: .delete(trash.appending(path: "Extensions")))],
                                                  prompt: "p") == [refused])
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
        #expect(try mover(shell, sandbox).perform([AdminStep(op: .delete(trash.appending(path: "y")))], prompt: "p")
            == [refused])
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
        #expect(try mover(shell, sandbox).perform([moveStep(trashed, original, expected: recorded)], prompt: "p")
            == [refused])
        #expect(shell.calls.first?.script.contains("\nmove_ 0 ") == true)
        #expect(size(trashed) == 7)
        #expect(ItemIdentity.of(trashed) != recorded)
        #expect(size(original) == -1)
        #expect(contents(sandbox.bridges).isEmpty)
    }

    @Test func putBackOfTheRecordedItemMoves() throws {
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/com.x.plist", bytes: 4)
        try sandbox.directory("Library/LaunchDaemons")
        let original = sandbox.root.appending(path: "Library/LaunchDaemons/com.x.plist")
        let recorded = try #require(ItemIdentity.of(trashed))
        #expect(try mover(UserShell(), sandbox).perform([moveStep(trashed, original, expected: recorded)], prompt: "p")
            == [.done])
        #expect(ItemIdentity.of(original) == recorded)
        #expect(size(trashed) == -1)
    }

    @Test func moveIntoAFolderTheUserCantWriteNeedsTheRecordedItem() throws {
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        #expect(chmod(folder.path(percentEncoded: false), 0o555) == 0)
        defer { _ = chmod(folder.path(percentEncoded: false), 0o755) }
        let destination = folder.appending(path: "helper")
        // The user really can't write the folder: without the recorded identity it never runs…
        let shell = UserShell()
        #expect(try mover(shell, sandbox).perform([moveStep(trashed, destination)], prompt: "p") == [unsafe])
        #expect(shell.calls.first?.script.hasSuffix("\nreport_ 0 unsafe\nexit 0\n") == true)
        #expect(size(trashed) == 4)
        // …with it, it is planned; the user-level shell then can't publish there (root could), so
        // the item goes back to the Trash.
        let recorded = try #require(ItemIdentity.of(trashed))
        #expect(try mover(shell, sandbox).perform([moveStep(trashed, destination, expected: recorded)], prompt: "p")
            == [refused])
        #expect(shell.calls.last?.script.contains("\nmove_ 0 - 0 \(recorded.stamp) 1 '") == true)
        #expect(ItemIdentity.of(trashed) == recorded)
        #expect(contents(folder).isEmpty)
        #expect(contents(sandbox.bridges).isEmpty)
    }

    @Test func putBackFromASwappedTrashIsRefused() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let victim = try sandbox.file("elsewhere/helper", bytes: 6)
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let realTrash = sandbox.root.appending(path: "home/Trash-real")
        let elsewhere = victim.deletingLastPathComponent()
        let recorded = try #require(ItemIdentity.of(trashed))
        let shell = UserShell(beforeRun: {
            try FileManager.default.moveItem(at: trash, to: realTrash)
            try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: elsewhere)
        })
        #expect(try mover(shell, sandbox, locked: { $0.hasSuffix("/PrivilegedHelperTools") }).perform(
            [moveStep(trashed, folder.appending(path: "helper"), expected: recorded)], prompt: "p") == [refused])
        #expect(size(victim) == 6)
        #expect(size(realTrash.appending(path: "helper")) == 4)
        #expect(contents(folder).isEmpty)
    }

    /// Every entry under the sandbox (relative path → size; -1 for a folder, -2 for a link).
    private func tree(_ sandbox: TestSandbox) -> [String: Int64] {
        let root = AdminPath.trimmingTrailingSlashes(sandbox.root.path(percentEncoded: false))
        var found: [String: Int64] = [:]
        for relative in (try? fm.subpathsOfDirectory(atPath: root)) ?? [] {
            var info = stat()
            guard lstat(root + "/" + relative, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFLNK: found[relative] = -2
            case S_IFDIR: found[relative] = -1
            default: found[relative] = Int64(info.st_size)
            }
        }
        return found
    }

    @Test func moveOutOfAFolderTheUserCanWriteWithASwappedItemIsRefused() throws {
        // r3review poc4, now allowed: the app is in a folder the user can write (like /Applications
        // for an admin). After planning another program swaps it for its own file. Root takes that
        // file into the bridge, finds it isn't the planned item and gives it back; nothing else is
        // touched. Planning is the real one except for where the bridge goes.
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.file("Applications/Foo.app/Contents/real", bytes: 6)
        let app = sandbox.root.appending(path: "Applications/Foo.app")
        let kept = sandbox.root.appending(path: "Applications/Foo-kept.app")
        let shell = UserShell(beforeRun: {
            try FileManager.default.moveItem(at: app, to: kept)
            try Data(count: 8).write(to: app)
        })
        let mover = try mover(shell, sandbox)
        let before = tree(sandbox)
        #expect(mover.perform([moveStep(app, trash.appending(path: "Foo.app"))], prompt: "p") == [refused])
        var expected = before.filter { !$0.key.hasPrefix("Applications/Foo.app") }
        expected["Applications/Foo.app"] = 8
        expected["Applications/Foo-kept.app"] = -1
        expected["Applications/Foo-kept.app/Contents"] = -1
        expected["Applications/Foo-kept.app/Contents/real"] = 6
        #expect(tree(sandbox) == expected)
        // Without the swap the same move goes through.
        try fm.removeItem(at: app)
        try fm.moveItem(at: kept, to: app)
        #expect(try self.mover(UserShell(), sandbox).perform([moveStep(app, trash.appending(path: "Foo.app"))],
                                                             prompt: "p") == [.done])
        #expect(size(trash.appending(path: "Foo.app/Contents/real")) == 6)
    }

    @Test func moveAcrossVolumesIsRefusedWhenPlanned() throws {
        let sandbox = try TestSandbox()
        try sandbox.directory("home/.Trash")
        let shell = UserShell()
        // /dev is its own file system, not the bridge's: the step must never reach mv (which would
        // copy and delete), and no bridge is made.
        let step = moveStep(URL(filePath: "/dev/null"), sandbox.environment.userTrash.appending(path: "null"))
        #expect(try mover(shell, sandbox).perform([step], prompt: "p") == [unsafe])
        #expect(shell.calls.first?.script.hasSuffix("\nown_=\(getuid())\nreport_ 0 unsafe\nexit 0\n") == true)
    }

    @Test func deleteChecksTheRecordedItem() throws {
        let sandbox = try TestSandbox()
        let swapped = try sandbox.file("home/.Trash/a", bytes: 4)
        let kept = try sandbox.file("home/.Trash/b", bytes: 4)
        let recordedA = try #require(ItemIdentity.of(swapped))
        let recordedB = try #require(ItemIdentity.of(kept))
        let shell = UserShell(beforeRun: { try Self.swap(swapped, bytes: 9) })
        let results = try mover(shell, sandbox).perform([
            AdminStep(op: .delete(swapped), expectedSource: recordedA),
            AdminStep(op: .delete(kept), expectedSource: recordedB),
        ], prompt: "p")
        #expect(results == [refused, .done])
        #expect(size(swapped) == 9)
        #expect(size(kept) == -1)
    }

    @Test func deleteOfAnItemSwappedAfterPlanningDeletesNothing() throws {
        // Empty Trash: after planning another program moves the planned item aside and puts
        // something else under its name (even without a recorded identity). Root takes it into the
        // bridge, finds it isn't the planned item and gives it back: nothing is deleted.
        let sandbox = try TestSandbox()
        let item = try sandbox.file("home/.Trash/old.log", bytes: 4)
        let aside = sandbox.root.appending(path: "home/.Trash/aside.log")
        let precious = try sandbox.file("home/Documents/precious", bytes: 9)
        let shell = UserShell(beforeRun: {
            try FileManager.default.moveItem(at: item, to: aside)
            try FileManager.default.moveItem(at: precious, to: item)
        })
        let mover = try mover(shell, sandbox)
        #expect(mover.perform([AdminStep(op: .delete(item))], prompt: "p") == [refused])
        #expect(size(item) == 9)
        #expect(size(aside) == 4)
        #expect(contents(sandbox.bridges).isEmpty)
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
