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
        // Nothing but result lines: a payload hidden in a name would print something else.
        #expect(output.split(separator: "\n").allSatisfy { $0.hasPrefix("R\t") }, "\(output)")
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

    /// Script text only (never run): planned folder identities are made up.
    private func text(_ steps: [AdminStep], folderOwner: uid_t = 501) -> String {
        AdminScript.make(steps, folders: steps.map { _ in ItemIdentity(device: 7, inode: 42, owner: folderOwner) })
    }

    /// How many `$name` / `${…}` expansions in a line are outside double quotes (a small sh
    /// tokenizer: single quotes, double quotes and nested `$( … )`).
    private func unquotedExpansions(in line: String) -> Int {
        let chars = Array(line)
        var doubleQuoted = [false]  // one entry per `$(` level
        var singleQuoted = false
        var count = 0
        var index = 0
        while index < chars.count {
            let character = chars[index]
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if singleQuoted {
                if character == "'" { singleQuoted = false }
            } else if character == "'", doubleQuoted.last == false {
                singleQuoted = true
            } else if character == "\"" {
                doubleQuoted[doubleQuoted.count - 1].toggle()
            } else if character == "$", next == "(" {
                doubleQuoted.append(false)
                index += 1
            } else if character == "$" {
                if doubleQuoted.last == false { count += 1 }
            } else if character == ")", doubleQuoted.count > 1, doubleQuoted.last == false {
                doubleQuoted.removeLast()
            }
            index += 1
        }
        return count
    }

    /// The step lines, after the functions.
    private func callLines(_ script: String) -> [String] {
        Array(script.dropFirst(AdminScript.prelude.count).split(separator: "\n").map(String.init))
    }

    @Test func bootOutLineOnlyForStepsThatAskForIt() throws {
        let daemon = URL(filePath: "/Library/LaunchDaemons/com.example.helper.plist")
        let cache = URL(filePath: "/Library/Caches/com.example")
        let script = text([
            AdminStep(op: .move(from: daemon, to: URL(filePath: "/Users/u/.Trash/com.example.helper.plist"),
                                bootOutDaemon: true)),
            AdminStep(op: .move(from: cache, to: URL(filePath: "/Users/u/.Trash/com.example"),
                                bootOutDaemon: false)),
        ])
        #expect(callLines(script) == [
            "move_ 0 - 1 - 0 '/Library/LaunchDaemons/com.example.helper.plist' '/Users/u/.Trash' 7:42:501 'com.example.helper.plist'",
            "move_ 1 - 0 - 0 '/Library/Caches/com.example' '/Users/u/.Trash' 7:42:501 'com.example'",
            "exit 0",
        ])
        // launchctl appears once, in move_, only behind the bootout flag ($3) and before the move.
        let bootOut = #"if [ "$3" = 1 ]; then /bin/launchctl bootout system "$6" >/dev/null 2>&1; fi"#
        #expect(script.components(separatedBy: "launchctl").count == 2)
        let bootOutAt = try #require(script.range(of: bootOut)).lowerBound
        let moveAt = try #require(script.range(of: #"/bin/mv -n -h -- "$6" "./$9""#)).lowerBound
        #expect(bootOutAt < moveAt)
    }

    @Test func scriptStartsSafelyAndUsesAbsoluteTools() {
        let script = text([
            AdminStep(op: .move(from: URL(filePath: "/Library/Caches/a"), to: URL(filePath: "/Users/u/.Trash/a"),
                                bootOutDaemon: false), dependsOn: nil),
            AdminStep(op: .delete(URL(filePath: "/Users/u/.Trash/b")), dependsOn: 0,
                      expectedSource: ItemIdentity(device: 1, inode: 2, owner: 0)),
        ])
        #expect(script.hasPrefix("set +e\nPATH=/usr/bin:/bin:/usr/sbin:/sbin\nexport PATH\n"))
        #expect(callLines(script) == [
            "move_ 0 - 0 - 0 '/Library/Caches/a' '/Users/u/.Trash' 7:42:501 'a'",
            "delete_ 1 0 1:2:0 '/Users/u/.Trash' 7:42:501 'b'",
            "exit 0",
        ])
        #expect(script.contains(#"/bin/mv -n -h -- "$6" "./$9" >/dev/null 2>&1"#))
        #expect(script.contains(#"/bin/rm -rf -- "./$6" >/dev/null 2>&1"#))
        #expect(script.contains(#"cd -P -- "$1""#))
        // In the functions, every expansion sits inside double quotes.
        #expect(unquotedExpansions(in: #"rm -rf $1 "$2" '$3' "$(id_ "$4") $5""#) == 1)
        for line in AdminScript.prelude.split(separator: "\n") {
            #expect(unquotedExpansions(in: String(line)) == 0, "\(line)")
        }
        #expect(!script.contains("eval"))
        #expect(script.hasSuffix("exit 0\n"))
    }

    @Test func moveBackOnlyIntoRootFolders() {
        let step = AdminStep(op: .move(from: URL(filePath: "/Users/u/.Trash/x"), to: URL(filePath: "/Library/x"),
                                       bootOutDaemon: false))
        #expect(callLines(text([step], folderOwner: 0)).first == "move_ 0 - 0 - 1 '/Users/u/.Trash/x' '/Library' 7:42:0 'x'")
        #expect(callLines(text([step], folderOwner: 501)).first == "move_ 0 - 0 - 0 '/Users/u/.Trash/x' '/Library' 7:42:501 'x'")
    }

    @Test func quoteEscapesEveryApostropheScalar() {
        let quoted = AdminScript.quote("a'\u{301}b'\u{FE0F}")
        #expect(Array(quoted.unicodeScalars) == Array("'a'\\''\u{301}b'\\''\u{FE0F}'".unicodeScalars))
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
            // A combining mark after the slash makes "/\u{301}" one Character, hiding the `..`
            // from Character-based splitting.
            URL(filePath: "/Users/u/.Trash/../\u{301}x"),
            URL(filePath: "/Users/u/.Trash/x\u{0}y"),
            URL(string: "https://example.com/Users/u")!,
        ]
        for url in unsafe {
            let script = text([
                AdminStep(op: .delete(url)),
                AdminStep(op: .move(from: url, to: URL(filePath: "/Users/u/.Trash/x"), bootOutDaemon: true)),
                AdminStep(op: .move(from: URL(filePath: "/Library/x"), to: url, bootOutDaemon: false)),
            ])
            #expect(callLines(script) == ["report_ 0 err", "report_ 1 err", "report_ 2 err", "exit 0"], "\(url)")
        }
        // A folder that is not a real directory at planning time (missing, or a link) is refused too.
        let planned = AdminScript.make([AdminStep(op: .delete(URL(filePath: "/nonexistent-dustling-folder/x")))])
        #expect(callLines(planned) == ["report_ 0 err", "exit 0"])
    }

    // MARK: - Hostile names

    @Test func quotingSurvivesHostileNames() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let names = [
            #"it's "q" $HOME `echo x` ;rm -rf ~ & é.app"#,
            "line\nbreak.txt",
            "back\\slash\ttab\rcr '\\'' -- *.log",
            // A combining mark or variation selector joins the quote before it into one Character.
            "a'\u{301};echo x;'b",
            "q\"\u{301}x",
            "b\\\u{301}x",
            "v'\u{FE0F}",
        ]
        let doomed = "d'\u{301};echo y;'z"
        try sandbox.file("Library/\(names[0])/Contents/Info.plist", bytes: 5)
        for (offset, name) in names.enumerated().dropFirst() {
            try sandbox.file("Library/\(name)", bytes: 10 + offset)
        }
        try sandbox.file("home/.Trash/\(doomed)", bytes: 3)
        try sandbox.file("Library/bystander.txt", bytes: 9)
        try sandbox.file("home/keep.txt", bytes: 9)
        let before = try snapshot(sandbox.root)

        let steps = names.map { name in
            move(sandbox.root.appending(path: "Library/\(name)"), trash.appending(path: name))
        } + [AdminStep(op: .delete(trash.appending(path: doomed)))]
        let results = run(steps)
        #expect(results == Array(repeating: .done, count: names.count + 1))

        var expected = Set<String>()
        for path in before where path != "home/.Trash/\(doomed)" {
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
        #expect(size(trash.appending(path: "\(names[0])/Contents/Info.plist")) == 5)
        for (offset, name) in names.enumerated().dropFirst() {
            #expect(size(trash.appending(path: name)) == Int64(10 + offset), "\(name.debugDescription)")
        }
        #expect(!exists(trash.appending(path: doomed)))
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
        // A quote or backslash followed by a combining mark is one Character; it must still be escaped.
        let joined = OsascriptAdminShell.appleScript(
            script: "q\"\u{301}x b\\\u{301}y", prompt: "p\"\u{FE0F}", privileged: true)
        let expected = "do shell script \"q\\\"\u{301}x b\\\\\u{301}y\" with prompt \"p\\\"\u{FE0F}\""
            + " with administrator privileges without altering line endings"
        #expect(Array(joined.utf8) == Array(expected.utf8))
    }

    @Test func osascriptExitIsMappedToAResult() {
        func map(_ status: Int32, _ stdout: String, _ stderr: String) -> AdminShellResult {
            OsascriptAdminShell.result(from: CommandResult(status: status, stdout: stdout, stderr: stderr))
        }
        #expect(map(0, "R\t0\tok\n\n", "") == .finished(output: "R\t0\tok\n"))
        #expect(map(0, "", "") == .finished(output: ""))
        #expect(map(1, "", "0:17: execution error: User canceled. (-128)\n") == .cancelled)
        #expect(map(1, "", "0:17: execution error: Kullanıcı vazgeçti. (-128)\n") == .cancelled)
        // Only the error number at the very end counts.
        #expect(map(1, "", "0:17: execution error: User canceled.\n")
            == .failed(reason: "0:17: execution error: User canceled."))
        #expect(map(1, "", "0:9: syntax error: (-128) in '/x' (-2741)\n")
            == .failed(reason: "0:9: syntax error: (-128) in '/x' (-2741)"))
        #expect(map(1, "", "0:9: execution error: (-1280)\n") == .failed(reason: "0:9: execution error: (-1280)"))
        #expect(map(1, "", "  0:37: execution error: hi (3)\n") == .failed(reason: "0:37: execution error: hi (3)"))
        #expect(map(1, "", "") == .failed(reason: "osascript stopped with status 1"))
        let tooMany = AdminShellResult.failed(
            reason: "Too many items for one password request. Try again with fewer items.")
        #expect(map(1, "", "0:5: execution error: sh: Argument list too long (7)\n") == tooMany)
        #expect(OsascriptAdminShell.result(from: NSError(domain: NSPOSIXErrorDomain, code: Int(E2BIG))) == tooMany)
        #expect(OsascriptAdminShell.result(from: NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(E2BIG)),
        ])) == tooMany)
        #expect(OsascriptAdminShell.result(from: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            != tooMany)
    }
}
