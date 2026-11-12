import Foundation
import Testing
@testable import DustlingCore

/// The scripts run for real, but only as the current user through `UserShell` (`/bin/sh -c`) and
/// only on paths inside a `TestSandbox`. `OsascriptAdminShell` is never built with privileges here:
/// that would put a password box on the screen.
struct AdminScriptTests {
    private let fm = FileManager.default

    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0
    }

    private func size(_ url: URL) -> Int64 {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0 ? Int64(st.st_size) : -1
    }

    private func run(_ steps: [AdminStep]) -> [AdminStepResult] {
        let script = AdminScript.make(steps)
        guard case .finished(let output) = UserShell().run(script: script, prompt: "test") else {
            Issue.record("the script did not finish")
            return []
        }
        return AdminScript.parse(output, count: steps.count)
    }

    private func move(_ from: URL, _ to: URL, dependsOn: Int? = nil) -> AdminStep {
        AdminStep(op: .move(from: from, to: to, bootOutDaemon: false), dependsOn: dependsOn)
    }

    /// Every entry under `root`, relative to it.
    private func snapshot(_ root: URL) throws -> Set<String> {
        Set(try fm.subpathsOfDirectory(atPath: root.path(percentEncoded: false)))
    }

    // MARK: - Moves

    @Test func moveMovesAndReportsOk() throws {
        let sandbox = try TestSandbox()
        let file = try sandbox.file("Library/Caches/a.bin", bytes: 16)
        try sandbox.file("Library/Caches/com.x/inner/b.bin", bytes: 8)
        let folder = sandbox.root.appending(path: "Library/Caches/com.x")
        let trash = try sandbox.directory("home/.Trash")
        let results = run([
            move(file, trash.appending(path: "a.bin")),
            move(folder, trash.appending(path: "com.x")),
        ])
        #expect(results == [.done, .done])
        #expect(!exists(file))
        #expect(!exists(folder))
        #expect(size(trash.appending(path: "a.bin")) == 16)
        #expect(size(trash.appending(path: "com.x/inner/b.bin")) == 8)
    }

    @Test func moveOfMissingSourceIsGone() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let missing = sandbox.root.appending(path: "Library/Caches/missing")
        let results = run([move(missing, trash.appending(path: "missing"))])
        #expect(results == [.notDone(reason: "already gone")])
        #expect(!exists(trash.appending(path: "missing")))
    }

    @Test func moveNeverOverwrites() throws {
        let sandbox = try TestSandbox()
        let source = try sandbox.file("Library/Caches/a.bin", bytes: 16)
        let taken = try sandbox.file("home/.Trash/a.bin", bytes: 3)
        let linkSource = try sandbox.file("Library/Caches/b.bin", bytes: 16)
        let danglingLink = sandbox.root.appending(path: "home/.Trash/b.bin")
        try fm.createSymbolicLink(
            atPath: danglingLink.path(percentEncoded: false), withDestinationPath: "/nonexistent/target")
        let results = run([move(source, taken), move(linkSource, danglingLink)])
        let exists = AdminStepResult.notDone(reason: "something with the same name is already there")
        #expect(results == [exists, exists])
        #expect(size(source) == 16)
        #expect(size(taken) == 3)
        #expect(size(linkSource) == 16)
        #expect(try fm.destinationOfSymbolicLink(atPath: danglingLink.path(percentEncoded: false))
            == "/nonexistent/target")
    }

    @Test func dependentStepIsSkippedWhenItsHeadFails() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let missingApp = sandbox.root.appending(path: "Applications/Gone.app")
        let goneLeftover = try sandbox.file("Library/Preferences/com.gone.plist", bytes: 4)
        let app = try sandbox.directory("Applications/Here.app")
        let hereLeftover = try sandbox.file("Library/Preferences/com.here.plist", bytes: 4)
        let results = run([
            move(missingApp, trash.appending(path: "Gone.app")),
            move(goneLeftover, trash.appending(path: "com.gone.plist"), dependsOn: 0),
            move(app, trash.appending(path: "Here.app")),
            move(hereLeftover, trash.appending(path: "com.here.plist"), dependsOn: 2),
        ])
        #expect(results == [
            .notDone(reason: "already gone"),
            .notDone(reason: "kept because the app itself was not removed"),
            .done,
            .done,
        ])
        #expect(size(goneLeftover) == 4)
        #expect(!exists(trash.appending(path: "com.gone.plist")))
        #expect(exists(trash.appending(path: "com.here.plist")))
    }

    @Test func stepDependingOnALaterOrUnknownStepIsSkipped() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let a = try sandbox.file("Library/a", bytes: 1)
        let b = try sandbox.file("Library/b", bytes: 1)
        let results = run([
            move(a, trash.appending(path: "a"), dependsOn: 1),
            move(b, trash.appending(path: "b"), dependsOn: 7),
        ])
        let skipped = AdminStepResult.notDone(reason: "kept because the app itself was not removed")
        #expect(results == [skipped, skipped])
        #expect(exists(a))
        #expect(exists(b))
    }

    @Test func bootOutLineOnlyForStepsThatAskForIt() throws {
        let daemon = URL(filePath: "/Library/LaunchDaemons/com.example.helper.plist")
        let cache = URL(filePath: "/Library/Caches/com.example")
        let script = AdminScript.make([
            AdminStep(op: .move(from: daemon, to: URL(filePath: "/Users/u/.Trash/com.example.helper.plist"),
                                bootOutDaemon: true), dependsOn: nil),
            AdminStep(op: .move(from: cache, to: URL(filePath: "/Users/u/.Trash/com.example"),
                                bootOutDaemon: false), dependsOn: nil),
        ])
        let blocks = script.components(separatedBy: "# step ")
        try #require(blocks.count == 3)
        let daemonStep = blocks[1]
        let bootOut = #"/bin/launchctl bootout system "$src" >/dev/null 2>&1"#
        #expect(daemonStep.contains("src='/Library/LaunchDaemons/com.example.helper.plist'\n"))
        #expect(daemonStep.components(separatedBy: bootOut).count == 2)
        let bootOutAt = try #require(daemonStep.range(of: bootOut)).lowerBound
        let moveAt = try #require(daemonStep.range(of: #"/bin/mv -n -- "$src" "$dst""#)).lowerBound
        #expect(bootOutAt < moveAt)
        #expect(!blocks[2].contains("launchctl"))
        #expect(script.components(separatedBy: "launchctl").count == 2)
    }

    @Test func scriptStartsSafelyAndUsesAbsoluteTools() {
        let script = AdminScript.make([
            AdminStep(op: .move(from: URL(filePath: "/Library/Caches/a"), to: URL(filePath: "/Users/u/.Trash/a"),
                                bootOutDaemon: false), dependsOn: nil),
            AdminStep(op: .delete(URL(filePath: "/Users/u/.Trash/b")), dependsOn: nil),
        ])
        #expect(script.hasPrefix("set +e\nPATH=/usr/bin:/bin:/usr/sbin:/sbin\n"))
        #expect(script.contains("\nsrc='/Library/Caches/a'\ndst='/Users/u/.Trash/a'\n"))
        #expect(script.contains(#"/bin/mv -n -- "$src" "$dst" >/dev/null 2>&1"#))
        #expect(script.contains("\nitem='/Users/u/.Trash/b'\n"))
        #expect(script.contains(#"/bin/rm -rf -- "$item" >/dev/null 2>&1"#))
        // The path variables are never used outside double quotes.
        for name in ["src", "dst", "item"] {
            let uses = script.components(separatedBy: "$\(name)").count - 1
            let quotedUses = script.components(separatedBy: "\"$\(name)\"").count - 1
            #expect(uses > 0 && uses == quotedUses, "\(name)")
        }
        #expect(!script.contains("eval"))
        #expect(script.hasSuffix("exit 0\n"))
    }

    // MARK: - Deletes

    @Test func deleteRemovesTree() throws {
        let sandbox = try TestSandbox()
        try sandbox.file("home/.Trash/pkg/Contents/MacOS/x", bytes: 8)
        try sandbox.file("home/.Trash/pkg/Contents/Info.plist", bytes: 8)
        let outside = try sandbox.file("outside/keep.bin", bytes: 8)
        let tree = sandbox.root.appending(path: "home/.Trash/pkg")
        try fm.createSymbolicLink(
            at: tree.appending(path: "Contents/link"), withDestinationURL: outside.deletingLastPathComponent())
        let missing = sandbox.root.appending(path: "home/.Trash/never-there")
        let results = run([
            AdminStep(op: .delete(tree), dependsOn: nil),
            AdminStep(op: .delete(missing), dependsOn: nil),
        ])
        #expect(results == [.done, .done])
        #expect(!exists(tree))
        #expect(size(outside) == 8)
    }

    @Test func trailingSlashNeverFollowsALink() throws {
        let sandbox = try TestSandbox()
        let target = try sandbox.file("outside/keep.bin", bytes: 8)
        let link = sandbox.root.appending(path: "home/.Trash/link")
        try sandbox.directory("home/.Trash")
        try fm.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        let withSlash = URL(filePath: link.path(percentEncoded: false) + "/", directoryHint: .isDirectory)
        #expect(withSlash.path(percentEncoded: false).hasSuffix("/"))
        let results = run([AdminStep(op: .delete(withSlash), dependsOn: nil)])
        #expect(results == [.done])
        #expect(!exists(link))
        #expect(size(target) == 8)
    }

    @Test func unsafePathsNeverReachATool() {
        let unsafe = [
            URL(filePath: "/"),
            URL(filePath: "/Users/u/.Trash/../../.."),
            URL(filePath: "/Users/u/./.Trash"),
            URL(string: "https://example.com/Users/u")!,
        ]
        for url in unsafe {
            let script = AdminScript.make([
                AdminStep(op: .delete(url), dependsOn: nil),
                AdminStep(op: .move(from: url, to: URL(filePath: "/Users/u/.Trash/x"), bootOutDaemon: true),
                          dependsOn: nil),
                AdminStep(op: .move(from: URL(filePath: "/Library/x"), to: url, bootOutDaemon: false),
                          dependsOn: nil),
            ])
            #expect(!script.contains("/bin/rm"), "\(url)")
            #expect(!script.contains("/bin/mv"), "\(url)")
            #expect(!script.contains("launchctl"), "\(url)")
            // Each of the three steps only reports `err`.
            #expect(script.components(separatedBy: "r=err").count == 4, "\(url)")
            let lines = script.split(separator: "\n").filter { $0.hasPrefix("printf 'R") }
            #expect(lines.count == 3, "\(url)")
        }
    }

    // MARK: - Hostile names

    @Test func quotingSurvivesHostileNames() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let names = [
            #"it's "q" $HOME `echo x` ;rm -rf ~ & é.app"#,
            "line\nbreak.txt",
            "back\\slash\ttab\rcr '\\'' -- *.log",
        ]
        try sandbox.file("Library/\(names[0])/Contents/Info.plist", bytes: 5)
        try sandbox.file("Library/\(names[1])", bytes: 6)
        try sandbox.file("Library/\(names[2])", bytes: 7)
        try sandbox.file("Library/bystander.txt", bytes: 9)
        try sandbox.file("home/keep.txt", bytes: 9)
        let before = try snapshot(sandbox.root)

        let results = run(names.map { name in
            move(sandbox.root.appending(path: "Library/\(name)"), trash.appending(path: name))
        })
        #expect(results == [.done, .done, .done])

        var expected = Set<String>()
        for path in before {
            var renamed = path
            for name in names {
                let from = "Library/\(name)"
                if path == from || path.hasPrefix(from + "/") {
                    renamed = "home/.Trash/\(name)" + path.dropFirst(from.count)
                }
            }
            expected.insert(renamed)
        }
        #expect(try snapshot(sandbox.root) == expected)
        #expect(size(trash.appending(path: names[1])) == 6)
        #expect(size(trash.appending(path: names[2])) == 7)
        #expect(size(trash.appending(path: "\(names[0])/Contents/Info.plist")) == 5)
    }

    // MARK: - Parsing

    @Test func parseMissingLinesAsNoResult() {
        let output = "R\t0\tok\nnoise\nR\t9\tok\nR\t1\twhat\nR\t-1\tok\nR\t2\tgone\n"
        #expect(AdminScript.parse(output, count: 3) == [
            .done,
            .notDone(reason: "no result"),
            .notDone(reason: "already gone"),
        ])
        #expect(AdminScript.parse("", count: 2) == [.notDone(reason: "no result"), .notDone(reason: "no result")])
        #expect(AdminScript.parse("R\t0\tok\n", count: 0) == [])
    }

    @Test func parseMapsEveryStatus() {
        let output = "R\t0\tok\nR\t1\tgone\nR\t2\tskip\nR\t3\texists\nR\t4\terr\n"
        #expect(AdminScript.parse(output, count: 5) == [
            .done,
            .notDone(reason: "already gone"),
            .notDone(reason: "kept because the app itself was not removed"),
            .notDone(reason: "something with the same name is already there"),
            .notDone(reason: "macOS refused, even with your password"),
        ])
    }

    @Test func parseKeepsTheFirstLineForAStep() {
        #expect(AdminScript.parse("R\t0\terr\nR\t0\tok\n", count: 1)
            == [.notDone(reason: "macOS refused, even with your password")])
    }

    // MARK: - osascript

    @Test func osascriptWithoutPrivilegesRunsScript() {
        let result = OsascriptAdminShell(privileged: false).run(script: "echo 'a\"b'", prompt: "x")
        #expect(result == .finished(output: "a\"b\n"))
    }

    @Test func appleScriptEscapesBackslashesAndQuotes() {
        let text = OsascriptAdminShell.appleScript(
            script: #"printf '%s\n' "a\b""#, prompt: #"say "hi" \o/"#, privileged: true)
        #expect(text == #"do shell script "printf '%s\\n' \"a\\b\"" with prompt "say \"hi\" \\o/" with administrator privileges without altering line endings"#)
        let plain = OsascriptAdminShell.appleScript(script: "echo \"x\"", prompt: "ignored", privileged: false)
        #expect(plain == #"do shell script "echo \"x\"" without altering line endings"#)
    }

    @Test func osascriptExitIsMappedToAResult() {
        func map(_ status: Int32, _ stdout: String, _ stderr: String) -> AdminShellResult {
            OsascriptAdminShell.result(from: CommandResult(status: status, stdout: stdout, stderr: stderr))
        }
        #expect(map(0, "R\t0\tok\n\n", "") == .finished(output: "R\t0\tok\n"))
        #expect(map(0, "", "") == .finished(output: ""))
        #expect(map(1, "", "0:17: execution error: User canceled. (-128)\n") == .cancelled)
        #expect(map(1, "", "0:17: execution error: Kullanıcı vazgeçti. (-128)\n") == .cancelled)
        #expect(map(1, "", "  0:37: execution error: hi (3)\n") == .failed(reason: "0:37: execution error: hi (3)"))
        #expect(map(1, "", "") == .failed(reason: "osascript stopped with status 1"))
    }
}
