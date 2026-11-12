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
        #expect(hidden(in: trash).isEmpty)
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

    /// Script text only (never run): what planning found is made up. Destination (or item)
    /// folders are 7:42:501, source folders 7:41:0, unless `sourceDevice` says otherwise.
    private func text(
        _ steps: [AdminStep], destinationWritable: Bool = true, sourceWritable: Bool = false, sourceDevice: UInt64 = 7
    ) -> String {
        let folder = AdminScript.PlannedFolder(
            identity: ItemIdentity(device: 7, inode: 42, owner: 501), userCanWrite: destinationWritable)
        let source = AdminScript.PlannedFolder(
            identity: ItemIdentity(device: sourceDevice, inode: 41, owner: 0), userCanWrite: sourceWritable)
        let plans = steps.map { step -> AdminScript.StepPlan in
            if case .move = step.op { return AdminScript.StepPlan(folder: folder, source: source) }
            return AdminScript.StepPlan(folder: folder, source: nil)
        }
        return AdminScript.make(steps, plans: plans, user: 501, token: "T0K3N")
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

    /// The step lines, after the functions and the `me_=` / `tok_=` lines.
    private func callLines(_ script: String) -> [String] {
        Array(script.dropFirst(AdminScript.prelude.count).split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("me_=") && !$0.hasPrefix("tok_=") })
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
            "move_ 0 - 1 - 1 '/Library/LaunchDaemons' 7:41:0 'com.example.helper.plist' '/Users/u/.Trash' 7:42:501 'com.example.helper.plist'",
            "move_ 1 - 0 - 1 '/Library/Caches' 7:41:0 'com.example' '/Users/u/.Trash' 7:42:501 'com.example'",
            "exit 0",
        ])
        // launchctl appears once, in move_, only behind the bootout flag: after the volume and
        // expected-identity checks and the staging folder, before any move.
        let bootOut = #"if [ "$b_" = 1 ]; then /bin/launchctl bootout system "$sd_/$sn_" >/dev/null 2>&1; fi"#
        #expect(script.components(separatedBy: "launchctl").count == 2)
        let bootOutAt = try #require(script.range(of: bootOut)).lowerBound
        let volumeCheckAt = try #require(script.range(of: #"[ "${sid_%%:*}" != "${did_%%:*}" ]"#)).lowerBound
        let expectedCheckAt = try #require(script.range(of: #"[ "$was_" != "$e_" ]"#)).lowerBound
        let stagingAt = try #require(script.range(of: "/bin/mkdir -m 700")).lowerBound
        #expect(volumeCheckAt < bootOutAt)
        #expect(expectedCheckAt < bootOutAt)
        #expect(stagingAt < bootOutAt)
        #expect(script.components(separatedBy: "/bin/mv ").count == 4)
        #expect(try #require(script.range(of: "/bin/mv ")).lowerBound > bootOutAt)
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
            "move_ 0 - 0 - 1 '/Library/Caches' 7:41:0 'a' '/Users/u/.Trash' 7:42:501 'a'",
            "delete_ 1 0 1:2:0 '/Users/u/.Trash' 7:42:501 'b'",
            "exit 0",
        ])
        #expect(script.contains("\nme_=501\ntok_=T0K3N\n"))
        // The only cross-folder rename: from the pinned source folder into the staging folder.
        #expect(script.contains(#"/bin/mv -n -h -- "./$sn_" "$dd_/$st_/$sn_" >/dev/null 2>&1"#))
        #expect(script.contains(#"/bin/mv -n -h -- "./$st_/$sn_" "./$st_/$dn_" >/dev/null 2>&1"#))
        #expect(script.contains(#"/bin/mv -n -h -- "./$st_/$dn_" . >/dev/null 2>&1"#))
        // Never a destination that mv could take for a folder to move into.
        #expect(!script.contains(#""./$dn_" >"#))
        #expect(script.contains(#"/bin/mkdir -m 700 -- "./$st_""#))
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

    @Test func planningRefusesUnsafeMoves() {
        let source = URL(filePath: "/Users/u/.Trash/x")
        let recorded = ItemIdentity(device: 7, inode: 99, owner: 0)
        let putBack = AdminStep(op: .move(from: source, to: URL(filePath: "/Library/x"), bootOutDaemon: false),
                                expectedSource: recorded)
        let unchecked = AdminStep(op: .move(from: source, to: URL(filePath: "/Library/x"), bootOutDaemon: false))
        let numbered = AdminStep(op: .move(from: URL(filePath: "/Library/x"), to: URL(filePath: "/Users/u/.Trash/x 2"),
                                           bootOutDaemon: false))
        let daemon = AdminStep(op: .move(from: URL(filePath: "/Library/LaunchDaemons/d.plist"),
                                         to: URL(filePath: "/Users/u/.Trash/d.plist"), bootOutDaemon: true))
        // Into a folder the user can't write: only with the recorded identity.
        #expect(callLines(text([putBack], destinationWritable: false, sourceWritable: true)).first
            == "move_ 0 - 0 7:99:0 1 '/Users/u/.Trash' 7:41:0 'x' '/Library' 7:42:501 'x'")
        #expect(callLines(text([unchecked], destinationWritable: false, sourceWritable: true)).first == "report_ 0 err")
        // Into a folder the user can write, also to a numbered name.
        #expect(callLines(text([numbered])).first
            == "move_ 0 - 0 - 0 '/Library' 7:41:0 'x' '/Users/u/.Trash' 7:42:501 'x 2'")
        // Never across volumes (mv would copy and delete instead of renaming).
        #expect(callLines(text([numbered], sourceDevice: 8)).first == "report_ 0 err")
        // Booting out a daemon whose plist folder the user could swap: refused.
        #expect(callLines(text([daemon], sourceWritable: true)).first == "report_ 0 err")
        #expect(callLines(text([daemon], sourceWritable: false)).first?.hasPrefix("move_ 0 - 1 - 1 ") == true)
    }

    @Test func quoteEscapesEveryApostropheScalar() {
        let quoted = AdminScript.quote("a'\u{301}b'\u{FE0F}")
        #expect(Array(quoted.unicodeScalars) == Array("'a'\\''\u{301}b'\\''\u{FE0F}'".unicodeScalars))
    }

    // MARK: - Moves into a folder the user can't write (staged)

    /// Runs `script` as the user and returns its output.
    private func output(of script: String) -> String {
        guard case .finished(let output) = UserShell().run(script: script, prompt: "test") else {
            Issue.record("the script did not finish")
            return ""
        }
        return output
    }

    private func hidden(in folder: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix(".dustling-") }
    }

    @Test func putBackIsStagedThenPublished() throws {
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/com.x.plist", bytes: 4)
        let folder = try sandbox.directory("Library/LaunchDaemons")
        let recorded = try #require(ItemIdentity.of(trashed))
        let step = AdminStep(op: .move(from: trashed, to: folder.appending(path: "com.x.plist"), bootOutDaemon: false),
                             expectedSource: recorded)
        // Planned as a folder the user can't write; it is writable here so the user-level shell can act.
        let real = try #require(AdminScript.plan(of: step))
        let plan = AdminScript.StepPlan(
            folder: AdminScript.PlannedFolder(identity: real.folder.identity, userCanWrite: false), source: real.source)
        let script = AdminScript.make([step], plans: [plan])
        #expect(script.contains("\nmove_ 0 - 0 \(recorded.stamp) 1 '"))
        #expect(AdminScript.parse(output(of: script), count: 1) == [.done])
        #expect(ItemIdentity.of(folder.appending(path: "com.x.plist")) == recorded)
        #expect(!exists(trashed))
        #expect(hidden(in: folder).isEmpty)
    }

    /// Puts back `helper` from the Trash into a folder, with a test-only `in_` that swaps another
    /// file in at `helper` just before root's rename (the third time a folder is pinned): what a
    /// program running as the user could do at that instant. `me_` is set to `user`.
    private func putBackWithSwap(in sandbox: TestSandbox, user: uid_t) throws
        -> (output: String, folder: URL, kept: URL)
    {
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let kept = sandbox.root.appending(path: "home/.Trash/kept")
        let impostor = try sandbox.file("impostor", bytes: 9)
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let step = AdminStep(op: .move(from: trashed, to: folder.appending(path: "helper"), bootOutDaemon: false),
                             expectedSource: try #require(ItemIdentity.of(trashed)))
        let real = try #require(AdminScript.plan(of: step))
        let plan = AdminScript.StepPlan(
            folder: AdminScript.PlannedFolder(identity: real.folder.identity, userCanWrite: false), source: real.source)
        let q = { (url: URL) in AdminScript.quote(url.path(percentEncoded: false)) }
        let swap = [
            "pins_=0",
            "in_() {",
            "  pins_=$((pins_ + 1))",
            "  if [ \"$pins_\" = 3 ]; then /bin/mv \(q(trashed)) \(q(kept)); /bin/cp \(q(impostor)) \(q(trashed)); fi",
            "  cd -P -- \"$1\" 2>/dev/null && [ \"$(id_ .)\" = \"$2\" ]",
            "}",
        ].joined(separator: "\n")
        let script = AdminScript.make([step], plans: [plan], user: user)
            .replacingOccurrences(of: "\nme_=", with: "\n\(swap)\nme_=")
        return (output(of: script), folder, kept)
    }

    @Test func swappedSourceIsNeverPublished() throws {
        // The impostor is the user's own: deleted, nothing published, the staging folder removed.
        let ownSandbox = try TestSandbox()
        let own = try putBackWithSwap(in: ownSandbox, user: getuid())
        #expect(own.output == "R\t0\terr\n")
        #expect(((try? fm.contentsOfDirectory(atPath: own.folder.path(percentEncoded: false))) ?? []).isEmpty)
        #expect(size(own.kept) == 4)
        // Someone else's (as seen by `me_`): kept inside the hidden staging folder, never published,
        // never moved back out.
        let otherSandbox = try TestSandbox()
        let other = try putBackWithSwap(in: otherSandbox, user: getuid() &+ 1)
        #expect(other.output == "R\t0\terr\n")
        let left = (try? fm.contentsOfDirectory(atPath: other.folder.path(percentEncoded: false))) ?? []
        #expect(left.count == 1 && left.first?.hasPrefix(".dustling-") == true)
        #expect(size(other.folder.appending(path: "\(left.first ?? "")/helper")) == 9)
        #expect(!exists(other.folder.appending(path: "helper")))
        #expect(size(other.kept) == 4)
    }

    @Test func trashSwappedJustBeforeTheRenameIsNeverUsed() throws {
        // Right after root re-pins the Trash (source folder) for the rename, the Trash is swapped
        // for a link to a folder holding a same-named item. The rename names the source relative to
        // the pinned folder, so it still takes the recorded item; the other item is never touched.
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let victim = try sandbox.file("elsewhere/helper", bytes: 6)
        let trash = sandbox.root.appending(path: "home/.Trash")
        let realTrash = sandbox.root.appending(path: "home/Trash-real")
        let elsewhere = sandbox.root.appending(path: "elsewhere")
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let recorded = try #require(ItemIdentity.of(trashed))
        let step = AdminStep(op: .move(from: trashed, to: folder.appending(path: "helper"), bootOutDaemon: false),
                             expectedSource: recorded)
        let q = { (url: URL) in AdminScript.quote(url.path(percentEncoded: false)) }
        let swap = [
            "pins_=0",
            "in_() {",
            "  pins_=$((pins_ + 1))",
            "  cd -P -- \"$1\" 2>/dev/null && [ \"$(id_ .)\" = \"$2\" ] || return 1",
            "  if [ \"$pins_\" = 3 ]; then /bin/mv \(q(trash)) \(q(realTrash)) && /bin/ln -s \(q(elsewhere)) \(q(trash)); fi",
            "}",
        ].joined(separator: "\n")
        let script = AdminScript.make([step]).replacingOccurrences(of: "\nme_=", with: "\n\(swap)\nme_=")
        #expect(AdminScript.parse(output(of: script), count: 1) == [.done])
        #expect((try? fm.destinationOfSymbolicLink(atPath: trash.path(percentEncoded: false))) != nil)
        #expect(ItemIdentity.of(folder.appending(path: "helper")) == recorded)
        #expect(size(victim) == 6)
        #expect(hidden(in: folder).isEmpty)
        #expect(!exists(realTrash.appending(path: "helper")))
    }

    @Test func stagingFolderMustBeNew() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let elsewhere = try sandbox.directory("elsewhere")
        let item = try sandbox.file("Library/Caches/a", bytes: 4)
        // Someone already put a link where the staging folder would be made.
        try fm.createSymbolicLink(at: trash.appending(path: ".dustling-T0K3N-0"), withDestinationURL: elsewhere)
        let step = move(item, trash.appending(path: "a"))
        let script = AdminScript.make([step], plans: [AdminScript.plan(of: step)], token: "T0K3N")
        #expect(AdminScript.parse(output(of: script), count: 1)
            == [.notDone(reason: "macOS refused, even with your password")])
        #expect(size(item) == 4)
        #expect(((try? fm.contentsOfDirectory(atPath: elsewhere.path(percentEncoded: false))) ?? []).isEmpty)
    }

    @Test func moveToANumberedNameWorks() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.file("home/.Trash/a.log", bytes: 1)
        let item = try sandbox.file("Library/Logs/a.log", bytes: 3)
        let script = AdminScript.make([move(item, trash.appending(path: "a 2.log"))])
        #expect(script.contains("\nmove_ 0 - 0 - 0 '"))
        #expect(AdminScript.parse(output(of: script), count: 1) == [.done])
        #expect(size(trash.appending(path: "a 2.log")) == 3)
        #expect(size(trash.appending(path: "a.log")) == 1)
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

    @Test func osascriptWithoutPrivilegesRunsScript() throws {
        let shell = OsascriptAdminShell(privileged: false)
        let result = shell.run(script: "echo 'a\"b'", prompt: "x")
        #expect(result == .finished(output: "a\"b\n"))
        // Nothing of Dustling's environment reaches the script's shell (this test process has HOME,
        // USER, TMPDIR…; bash would also run code from BASH_FUNC_*%%, SHELLOPTS or PS4).
        guard case .finished(let environment) = shell.run(script: "/usr/bin/env", prompt: "x") else {
            Issue.record("env did not run")
            return
        }
        let names = Set(environment.split(separator: "\n").map { String($0.prefix { $0 != "=" }) })
        #expect(names.isSubset(of: ["PATH", "PWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"]), "\(names)")
        #expect(environment.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"))
        #expect(OsascriptAdminShell.childEnvironment == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    @Test func processRunnerCanReplaceTheEnvironment() throws {
        let poisoned = [
            "PATH": "/usr/bin:/bin",
            "BASH_FUNC_printf%%": "() { /bin/echo pwned; }",
            "SHELLOPTS": "xtrace",
            "PS4": "$(/bin/echo pwned >&2)",
        ]
        // The threat: bash (which /bin/sh is) obeys such variables before the first line of a script…
        let obeyed = try ProcessCommandRunner().run("/bin/bash", ["-c", "printf '%s\\n' ok"], environment: poisoned)
        #expect(obeyed.stdout == "pwned\n")
        // …so the admin shell starts osascript with exactly its own environment.
        let clean = try ProcessCommandRunner().run(
            "/bin/bash", ["-c", "printf '%s\\n' ok"], environment: OsascriptAdminShell.childEnvironment)
        #expect(clean.stdout == "ok\n")
        #expect(clean.stderr.isEmpty)
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
