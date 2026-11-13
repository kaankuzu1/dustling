import Foundation
import Testing
@testable import DustlingCore

/// The scripts run for real, but only as the current user through `UserShell` (`/bin/sh -c`) and
/// only on paths inside a `TestSandbox`. `OsascriptAdminShell` is never built with privileges here:
/// that would put a password box on the screen. A test can't make root-owned folders, so planning
/// makes the bridge in the sandbox (`TestSandbox.adminPlanning`), owned by the user.
struct AdminScriptTests {
    private let fm = FileManager.default

    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(path(url), &st) == 0
    }

    private func size(_ url: URL) -> Int64 {
        var st = stat()
        return lstat(path(url), &st) == 0 ? Int64(st.st_size) : -1
    }

    /// The path as the script gets it: no trailing slash.
    private func path(_ url: URL) -> String {
        AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false))
    }

    private func contents(_ url: URL) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: path(url))) ?? [])
    }

    private func run(_ steps: [AdminStep], in sandbox: TestSandbox) throws -> [AdminStepResult] {
        let script = AdminScript.make(steps, planning: try sandbox.adminPlanning())
        guard case .finished(let output) = UserShell().run(script: script, prompt: "test") else {
            Issue.record("the script did not finish")
            return []
        }
        // Nothing but result lines: a payload hidden in a name would print something else.
        #expect(output.split(separator: "\n").allSatisfy { $0.hasPrefix("R\t") }, "\(output)")
        #expect(contents(sandbox.bridges).isEmpty)
        return AdminScript.parse(output, count: steps.count)
    }

    private func move(_ from: URL, _ to: URL, dependsOn: Int? = nil) -> AdminStep {
        AdminStep(op: .move(from: from, to: to, bootOutDaemon: false), dependsOn: dependsOn)
    }

    /// Every entry under `root`, relative to it.
    private func snapshot(_ root: URL) throws -> Set<String> {
        Set(try fm.subpathsOfDirectory(atPath: path(root)))
    }

    /// Every entry under the sandbox (relative path → size; -1 for a folder, -2 for a link), read
    /// with lstat and never through a link.
    private func tree(_ sandbox: TestSandbox) -> [String: Int64] {
        var found: [String: Int64] = [:]
        func walk(_ relative: String) {
            let folder = path(sandbox.root) + (relative.isEmpty ? "" : "/" + relative)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let child = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(folder + "/" + name, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFLNK: found[child] = -2
                case S_IFDIR: found[child] = -1; walk(child)
                default: found[child] = Int64(info.st_size)
                }
            }
        }
        walk("")
        return found
    }

    /// `before` with every entry at or under `removed` taken out and `added` put in.
    private func changed(_ before: [String: Int64], removing removed: [String] = [], adding added: [String: Int64])
        -> [String: Int64]
    {
        var expected = before.filter { entry in
            !removed.contains { entry.key == $0 || entry.key.hasPrefix($0 + "/") }
        }
        expected.merge(added) { $1 }
        return expected
    }

    // MARK: - Moves

    @Test func moveMovesAndReportsOk() throws {
        let sandbox = try TestSandbox()
        let file = try sandbox.file("Library/Caches/a.bin", bytes: 16)
        try sandbox.file("Library/Caches/com.x/inner/b.bin", bytes: 8)
        let folder = sandbox.root.appending(path: "Library/Caches/com.x")
        let trash = try sandbox.directory("home/.Trash")
        let results = try run([
            move(file, trash.appending(path: "a.bin")),
            move(folder, trash.appending(path: "com.x")),
        ], in: sandbox)
        #expect(results == [.done, .done])
        #expect(!exists(file))
        #expect(!exists(folder))
        #expect(size(trash.appending(path: "a.bin")) == 16)
        #expect(size(trash.appending(path: "com.x/inner/b.bin")) == 8)
    }

    @Test func moveOfMissingSourceIsGone() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.directory("Library/Caches")
        let results = try run([
            move(sandbox.root.appending(path: "Library/Caches/missing"), trash.appending(path: "missing")),
            move(sandbox.root.appending(path: "Library/Gone/missing"), trash.appending(path: "missing 2")),
        ], in: sandbox)
        #expect(results == [.notDone(reason: "already gone"), .notDone(reason: "already gone")])
        #expect(contents(trash).isEmpty)
    }

    @Test func moveNeverOverwrites() throws {
        let sandbox = try TestSandbox()
        let source = try sandbox.file("Library/Caches/a.bin", bytes: 16)
        let taken = try sandbox.file("home/.Trash/a.bin", bytes: 3)
        let linkSource = try sandbox.file("Library/Caches/b.bin", bytes: 16)
        let danglingLink = sandbox.root.appending(path: "home/.Trash/b.bin")
        try fm.createSymbolicLink(atPath: path(danglingLink), withDestinationPath: "/nonexistent/target")
        let results = try run([move(source, taken), move(linkSource, danglingLink)], in: sandbox)
        let exists = AdminStepResult.notDone(reason: "something with the same name is already there")
        #expect(results == [exists, exists])
        #expect(size(source) == 16)
        #expect(size(taken) == 3)
        #expect(size(linkSource) == 16)
        #expect(try fm.destinationOfSymbolicLink(atPath: path(danglingLink)) == "/nonexistent/target")
    }

    @Test func dependentStepIsSkippedWhenItsHeadFails() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let missingApp = sandbox.root.appending(path: "Applications/Gone.app")
        let goneLeftover = try sandbox.file("Library/Preferences/com.gone.plist", bytes: 4)
        let app = try sandbox.directory("Applications/Here.app")
        let hereLeftover = try sandbox.file("Library/Preferences/com.here.plist", bytes: 4)
        let results = try run([
            move(missingApp, trash.appending(path: "Gone.app")),
            move(goneLeftover, trash.appending(path: "com.gone.plist"), dependsOn: 0),
            move(app, trash.appending(path: "Here.app")),
            move(hereLeftover, trash.appending(path: "com.here.plist"), dependsOn: 2),
        ], in: sandbox)
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
        let results = try run([
            move(a, trash.appending(path: "a"), dependsOn: 1),
            move(b, trash.appending(path: "b"), dependsOn: 7),
        ], in: sandbox)
        let skipped = AdminStepResult.notDone(reason: "kept because the app itself was not removed")
        #expect(results == [skipped, skipped])
        #expect(exists(a))
        #expect(exists(b))
    }

    @Test func moveToANumberedNameWorks() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.file("home/.Trash/a.log", bytes: 1)
        let item = try sandbox.file("Library/Logs/a.log", bytes: 3)
        let script = AdminScript.make([move(item, trash.appending(path: "a 2.log"))], planning: try sandbox.adminPlanning())
        #expect(script.contains("\nmove_ 0 - 0 - 0 '"))
        #expect(AdminScript.parse(output(of: script), count: 1) == [.done])
        #expect(size(trash.appending(path: "a 2.log")) == 3)
        #expect(size(trash.appending(path: "a.log")) == 1)
        #expect(contents(sandbox.bridges).isEmpty)
    }

    // MARK: - Script text (never run)

    /// Script text only: what planning found is made up. Destination (or delete) folders are
    /// 7:42:501, source folders 7:41:0, items 7:99:0; the bridge goes in /Library on volume 7.
    private func text(
        _ steps: [AdminStep], destinationWritable: Bool = true, sourceRootOnly: Bool = true,
        itemDevice: UInt64 = 7, folderDevice: UInt64 = 7, bridge: Bool = true
    ) -> String {
        let folder = AdminScript.PlannedFolder(
            identity: ItemIdentity(device: folderDevice, inode: 42, owner: 501),
            userCanWrite: destinationWritable, rootOnlyChain: false)
        let source = AdminScript.PlannedFolder(
            identity: ItemIdentity(device: 7, inode: 41, owner: 0), userCanWrite: false, rootOnlyChain: sourceRootOnly)
        let item = ItemIdentity(device: itemDevice, inode: 99, owner: 0)
        let plans = steps.map { step -> AdminScript.StepPlan in
            if case .move = step.op { return AdminScript.StepPlan(folder: folder, source: source, item: item) }
            return AdminScript.StepPlan(folder: folder, source: nil, item: item)
        }
        let planned = bridge ? AdminScript.PlannedBridge(parent: "/Library", device: 7, owner: 0) : nil
        return AdminScript.make(steps, plans: plans, bridge: planned, isTrash: { $0 == "/Users/u/.Trash" })
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

    /// The step lines, after the functions and without the `own_=`, `bridge_` and `end_` lines.
    private func callLines(_ script: String) -> [String] {
        Array(script.dropFirst(AdminScript.prelude.count).split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("own_=") && !$0.hasPrefix("bridge_ ") && $0 != "end_" })
    }

    /// The body of the sh function `name` in the prelude, up to the line that closes it.
    private func body(of name: String) throws -> String {
        let prelude = AdminScript.prelude
        let start = try #require(prelude.range(of: "\n\(name)() {\n")).upperBound
        let end = try #require(prelude.range(of: "\n}", range: start..<prelude.endIndex)).lowerBound
        return String(prelude[start..<end])
    }

    /// Where `needle` first appears in `text` (as an offset), or fails the test.
    private func offset(of needle: String, in text: String) throws -> Int {
        let range = try #require(text.range(of: needle), "\(needle)")
        return text.distance(from: text.startIndex, to: range.lowerBound)
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
            "move_ 0 - 1 - 1 '/Library/LaunchDaemons' 7:41:0 'com.example.helper.plist' 7:99:0 '/Users/u/.Trash' 7:42:501 'com.example.helper.plist'",
            "move_ 1 - 0 - 1 '/Library/Caches' 7:41:0 'com.example' 7:99:0 '/Users/u/.Trash' 7:42:501 'com.example'",
            "exit 0",
        ])
        // launchctl appears once, in boot_: behind the flag, in the pinned plist folder, only for the
        // planned item, a regular file that is not a link.
        #expect(script.components(separatedBy: "launchctl").count == 2)
        let boot = try body(of: "boot_")
        #expect(boot.contains(#"[ "$b_" = 1 ] && pin_ "$sd_" "$sid_" && [ "$(id_ "./$sn_")" = "$iid_" ]"#))
        #expect(boot.contains(#"&& [ -f "./$sn_" ] && ! [ -L "./$sn_" ]; then"#))
        #expect(boot.contains(#"/bin/launchctl bootout system "$sd_/$sn_" >/dev/null 2>&1"#))
        // In a move, after the bridge and the destination check, before the item is taken.
        let move = try body(of: "move_")
        let bootAt = try offset(of: "\n  boot_\n", in: move)
        #expect(try offset(of: #"[ "$bok_" != 1 ]"#, in: move) < bootAt)
        #expect(try offset(of: #"if at_ "./$dn_"; then report_ "$i_" exists"#, in: move) < bootAt)
        #expect(try offset(of: "take_ ", in: move) > bootAt)
        #expect(try offset(of: "/bin/mv ", in: move) > bootAt)
    }

    @Test func scriptStartsSafelyAndUsesAbsoluteTools() throws {
        let script = text([
            AdminStep(op: .move(from: URL(filePath: "/Library/Caches/a"), to: URL(filePath: "/Users/u/.Trash/a"),
                                bootOutDaemon: false), dependsOn: nil),
            AdminStep(op: .delete(URL(filePath: "/Users/u/.Trash/b")), dependsOn: 0,
                      expectedSource: ItemIdentity(device: 7, inode: 99, owner: 0)),
        ])
        #expect(script.hasPrefix("set +e\numask 077\nPATH=/usr/bin:/bin:/usr/sbin:/sbin\nexport PATH\n"))
        #expect(callLines(script) == [
            "move_ 0 - 0 - 1 '/Library/Caches' 7:41:0 'a' 7:99:0 '/Users/u/.Trash' 7:42:501 'a'",
            "delete_ 1 0 7:99:0 '/Users/u/.Trash' 7:42:501 'b' 7:99:0",
            "exit 0",
        ])
        #expect(script.contains("\nown_=0\nbridge_ '/Library' 7\nmove_ 0 "))
        #expect(script.hasSuffix("\nend_\nexit 0\n"))
        // The bridge: made fresh by mktemp, its inherited ACL removed, then checked.
        let bridge = try body(of: "bridge_")
        #expect(bridge.contains(#"br_=$(/usr/bin/mktemp -d "$1/.dustling-XXXXXXXX" 2>/dev/null) || br_="#))
        #expect(bridge.contains(#"! [ -L "$br_" ] && [ -d "$br_" ] && /bin/chmod -N "$br_" 2>/dev/null"#))
        #expect(bridge.contains(#"[ "$(/usr/bin/stat -f '%d:%u:%Lp' -- "$br_")" = "$2:$own_:700" ] && empty_ "$br_""#))
        // Every path a tool gets is the bridge, a step's folder in it (`$k_`), `.` or `./<name>` of
        // a pinned folder: never a path through any other folder.
        var operands: [String] = []
        for line in AdminScript.prelude.split(separator: "\n").map(String.init) where !line.hasPrefix("rn_() {") {
            for tool in ["/bin/mv ", "/bin/rm ", "/bin/mkdir ", "/bin/rmdir ", "/bin/chmod ", "rn_ "] {
                guard let range = line.range(of: tool) else { continue }
                var rest = line[range.upperBound...]
                for stop in [" >", " 2>", ";", " ||", " \\"] {
                    if let end = rest.range(of: stop) { rest = rest[..<end.lowerBound] }
                }
                operands += rest.split(separator: " ").map(String.init)
                    .filter { !$0.hasPrefix("-") && !$0.allSatisfy(\.isNumber) }
            }
        }
        #expect(operands.count == 15, "\(operands)")
        for operand in operands {
            #expect(operand == "." || operand.hasPrefix(#""./"#) || operand.hasPrefix(#""$k_"#)
                || operand == #""$br_""#, "\(operand)")
        }
        #expect(script.contains(#"rn_ "./$3" "$k_"; fi"#))
        #expect(script.contains(#"rn_ "$k_/$3" .; fi"#))
        #expect(script.contains(#"rn_ "$k_/$dn_" .; fi"#))
        #expect(script.contains(#"/bin/rm -rfx -- "$k_/$6" >/dev/null 2>&1"#))
        #expect(script.contains(#"/bin/mkdir -m 700 -- "$k_" 2>/dev/null"#))
        // Folders are entered by path only in pin_, and checked there.
        #expect(script.components(separatedBy: "cd -P").count == 2)
        #expect(script.contains(#"pin_() { cd -P -- "$1" 2>/dev/null && [ "$(id_ .)" = "$2" ]; }"#))
        #expect(!script.contains("chown"))
        // In the functions, every expansion sits inside double quotes.
        #expect(unquotedExpansions(in: #"rm -rf $1 "$2" '$3' "$(id_ "$4") $5""#) == 1)
        for line in AdminScript.prelude.split(separator: "\n") {
            #expect(unquotedExpansions(in: String(line)) == 0, "\(line)")
        }
        #expect(!script.contains("eval"))
    }

    @Test func everyRenameOutOfAFolderOrTheBridgeChecksTheItemRightBefore() throws {
        // Out of a pinned folder: the entry must still be the planned item (lstat: a mount there
        // is another volume), checked on the same line as the rename.
        #expect(try body(of: "take_").contains(#"if [ "$(id_ "./$3")" = "$4" ]; then rn_ "./$3" "$k_"; fi"#))
        // Out of the bridge (giving back, publishing): only the inode root took, onto a free name.
        let back = #"back_() { if pin_ "$1" "$2" && [ "$(id_ "$k_/$3")" = "$4" ] && ! at_ "./$3"; then rn_ "$k_/$3" .; fi; }"#
        #expect(AdminScript.prelude.contains("\n\(back)\n"))
        let publish = #"if pin_ "$dd_" "$did_" && [ "$(id_ "$k_/$dn_")" = "$iid_" ] && ! at_ "./$dn_"; then rn_ "$k_/$dn_" .; fi"#
        #expect(try body(of: "move_").contains(publish))
        #expect(try body(of: "move_").contains(#"back_ "$sd_" "$sid_" "$sn_" "$iid_""#))
        // Only the planned item left in the bridge is `held` (and gets the bridge's path, once).
        #expect(AdminScript.prelude.contains(
            #"if { [ "$2" = held ] || [ "$2" = partial ]; } && [ "$bp_" != 1 ]; then printf 'B\t%s\n' "$br_"; bp_=1; fi"#))
        #expect(try body(of: "move_").contains(
            #"elif [ "$(id_ "$k_/$sn_")" = "$iid_" ] || [ "$(id_ "$k_/$dn_")" = "$iid_" ]; then fin_ held"#))
        #expect(try body(of: "take_").contains(#"elif ! empty_ "$k_"; then t_=held_other; fi"#))
    }

    @Test func onlyZshsRenameCrossesFolders() throws {
        // /bin/mv copies (cp -PRp) and removes the source (rm -rf) when rename(2) fails across
        // volumes, and its copy follows a link at the target. Every rename between folders is rn_:
        // zsh's zf_mv builtin, plain rename(2), with no startup files and nothing from the environment.
        #expect(AdminScript.prelude.contains("\nrn_() { \(Self.rnBody); }\n"))
        let lines = AdminScript.prelude.split(separator: "\n").map(String.init)
        // rn_ is called three times, always in folder form: the target is `.` or the step's bridge folder.
        let calls = lines.filter { $0.contains("rn_ \"") && !$0.hasPrefix("rn_() {") }
        #expect(calls.count == 3)
        for call in calls {
            #expect(call.hasSuffix(#"then rn_ "./$3" "$k_"; fi"#) || call.hasSuffix(#" .; fi"#)
                || call.hasSuffix(#" .; fi; }"#), "\(call)")
        }
        // /bin/mv is left only for renames inside a step's own bridge folder (root-only; one folder,
        // one volume), to give the item its final name and back.
        let moves = lines.filter { $0.contains("/bin/mv ") }
        #expect(moves == [
            #"  if [ "$same_" != 1 ]; then /bin/mv -n -h -- "$k_/$sn_" "$k_/$dn_" >/dev/null 2>&1; fi"#,
            #"    if [ "$same_" != 1 ]; then /bin/mv -n -h -- "$k_/$dn_" "$k_/$sn_" >/dev/null 2>&1; fi"#,
        ])
        #expect(!AdminScript.prelude.contains("/bin/cp"))
    }

    @Test func planningRefusesUnsafeSteps() {
        let trashed = URL(filePath: "/Users/u/.Trash/x")
        let planned = ItemIdentity(device: 7, inode: 99, owner: 0)
        let putBack = AdminStep(op: .move(from: trashed, to: URL(filePath: "/Library/x"), bootOutDaemon: false),
                                expectedSource: planned)
        let unchecked = AdminStep(op: .move(from: trashed, to: URL(filePath: "/Library/x"), bootOutDaemon: false))
        let numbered = AdminStep(op: .move(from: URL(filePath: "/Applications/x"), to: URL(filePath: "/Users/u/.Trash/x 2"),
                                           bootOutDaemon: false))
        let daemon = AdminStep(op: .move(from: URL(filePath: "/Library/LaunchDaemons/d.plist"),
                                         to: URL(filePath: "/Users/u/.Trash/d.plist"), bootOutDaemon: true))
        let delete = AdminStep(op: .delete(trashed))
        // Into a folder the user can't write: only with the recorded identity. Refused Put backs (out
        // of the Trash) have their own status, so the reason can point to Finder's Put Back.
        #expect(callLines(text([putBack], destinationWritable: false)).first
            == "move_ 0 - 0 7:99:0 1 '/Users/u/.Trash' 7:41:0 'x' 7:99:0 '/Library' 7:42:501 'x'")
        #expect(callLines(text([unchecked], destinationWritable: false)).first == "report_ 0 unsafe_putback")
        #expect(callLines(text([putBack], destinationWritable: false, itemDevice: 8)).first == "report_ 0 unsafe_putback")
        #expect(callLines(text([putBack], bridge: false)).first == "report_ 0 unsafe_putback")
        // Into a folder the user can write, from any folder, also to a numbered name.
        #expect(callLines(text([unchecked])).first?.hasPrefix("move_ 0 - 0 - 1 ") == true)
        #expect(callLines(text([numbered], sourceRootOnly: false)).first
            == "move_ 0 - 0 - 0 '/Applications' 7:41:0 'x' 7:99:0 '/Users/u/.Trash' 7:42:501 'x 2'")
        // The recorded identity isn't what planning sees: refused.
        let other = AdminStep(op: .move(from: trashed, to: URL(filePath: "/Library/x"), bootOutDaemon: false),
                              expectedSource: ItemIdentity(device: 7, inode: 98, owner: 0))
        #expect(callLines(text([other], destinationWritable: false)).first == "report_ 0 err")
        // Off the bridge's volume (mv would copy and delete instead of renaming), or no bridge.
        #expect(callLines(text([numbered], itemDevice: 8)).first == "report_ 0 unsafe")
        #expect(callLines(text([numbered], folderDevice: 8)).first == "report_ 0 unsafe")
        #expect(callLines(text([numbered], bridge: false)) == ["report_ 0 unsafe", "exit 0"])
        #expect(callLines(text([delete], itemDevice: 8)).first == "report_ 0 unsafe")
        #expect(callLines(text([delete], bridge: false)).first == "report_ 0 unsafe")
        #expect(!text([numbered], bridge: false).contains("\nbridge_ "))
        // Booting out a daemon whose plist folder chain isn't root-only: refused.
        #expect(callLines(text([daemon], sourceRootOnly: false)).first == "report_ 0 unsafe")
        #expect(callLines(text([daemon])).first?.hasPrefix("move_ 0 - 1 - 1 ") == true)
    }

    @Test func everyStepHasATrashAtOneEnd() {
        // A move out of a folder that isn't a Trash goes only into one; into a folder the user can't
        // write, only out of a Trash; root deletes only what is directly in a Trash.
        let planned = ItemIdentity(device: 7, inode: 99, owner: 0)
        func move(_ from: String, _ to: String, expected: ItemIdentity? = nil) -> AdminStep {
            AdminStep(op: .move(from: URL(filePath: from), to: URL(filePath: to), bootOutDaemon: false),
                      expectedSource: expected)
        }
        let sideways = move("/Library/Caches/x", "/Users/u/Library/Caches/x", expected: planned)
        let intoLockedTrash = move("/Library/Caches/x", "/Users/u/.Trash/x", expected: planned)
        let fromInsideTheTrash = move("/Users/u/.Trash/a/x", "/Library/x", expected: planned)
        #expect(callLines(text([sideways])).first == "report_ 0 unsafe")
        #expect(callLines(text([sideways], destinationWritable: false)).first == "report_ 0 unsafe")
        #expect(callLines(text([intoLockedTrash], destinationWritable: false)).first == "report_ 0 unsafe")
        #expect(callLines(text([fromInsideTheTrash], destinationWritable: false)).first == "report_ 0 unsafe")
        #expect(callLines(text([intoLockedTrash])).first?.hasPrefix("move_ 0 - 0 7:99:0 1 ") == true)
        for path in ["/Library/Caches/x", "/Users/u/.Trash/a/x", "/Users/u/x"] {
            #expect(callLines(text([AdminStep(op: .delete(URL(filePath: path)))])).first == "report_ 0 unsafe", "\(path)")
        }
        #expect(callLines(text([AdminStep(op: .delete(URL(filePath: "/Users/u/.Trash/x")))])).first?
            .hasPrefix("delete_ 0 - - '/Users/u/.Trash' ") == true)
    }

    @Test func putBackGoesOnlyIntoTheFolderItChecked() {
        let trashed = URL(filePath: "/Users/u/.Trash/x")
        let planned = ItemIdentity(device: 7, inode: 99, owner: 0)
        func putBack(into folder: ItemIdentity) -> AdminStep {
            AdminStep(op: .move(from: trashed, to: URL(filePath: "/Library/x"), bootOutDaemon: false),
                      expectedSource: planned, expectedFolder: folder)
        }
        // Planning found the destination folder 7:42:501 (`text`).
        #expect(callLines(text([putBack(into: ItemIdentity(device: 7, inode: 43, owner: 501))],
                               destinationWritable: false)).first == "report_ 0 unsafe_putback")
        #expect(callLines(text([putBack(into: ItemIdentity(device: 7, inode: 42, owner: 0))],
                               destinationWritable: false)).first == "report_ 0 unsafe_putback")
        #expect(callLines(text([putBack(into: ItemIdentity(device: 7, inode: 42, owner: 501))], destinationWritable: false))
            .first == "move_ 0 - 0 7:99:0 1 '/Users/u/.Trash' 7:41:0 'x' 7:99:0 '/Library' 7:42:501 'x'")
    }

    @Test func planningSeesMissingItemsAndFolders() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.directory("Library/Caches")
        let planning = try sandbox.adminPlanning()
        let script = AdminScript.make([
            move(sandbox.root.appending(path: "Library/Caches/missing"), trash.appending(path: "missing")),
            move(sandbox.root.appending(path: "Library/Gone/x"), trash.appending(path: "x")),
            AdminStep(op: .delete(trash.appending(path: "never"))),
            AdminStep(op: .delete(sandbox.root.appending(path: "nowhere/x"))),
        ], planning: planning)
        let lines = callLines(script)
        #expect(lines[0] == "gone_ 0 -")
        #expect(lines[1] == "gone_ 1 -")
        #expect(lines[2].hasPrefix("delete_ 2 - - '") && lines[2].hasSuffix(" 'never' -"))
        // A folder that isn't a real directory when planned (missing, or a link): refused.
        #expect(lines[3] == "report_ 3 unsafe")
    }

    @Test func planningReadsAFolderThroughOneDescriptor() throws {
        // A folder is opened once (O_DIRECTORY | O_NOFOLLOW); its identity, whether the user can
        // write it and the item in it all come from that descriptor. Another program that swaps
        // what is at the path right after the open can't make planning mix two folders.
        let sandbox = try TestSandbox()
        let place = try sandbox.directory("place")
        try sandbox.file("place/item", bytes: 2)
        let locked = try sandbox.directory("locked")
        try sandbox.file("locked/item", bytes: 3)
        #expect(chmod(path(locked), 0o555) == 0)
        defer { _ = chmod(path(place), 0o755); _ = chmod(path(locked), 0o755) }
        let writable = try #require(ItemIdentity.of(place))
        let writableItem = try #require(ItemIdentity.of(place.appending(path: "item")))
        let readOnly = try #require(ItemIdentity.of(locked))
        let readOnlyItem = try #require(ItemIdentity.of(locked.appending(path: "item")))
        let planning = try sandbox.adminPlanning()
        let (a, b) = (path(place), path(locked))
        let swap = { _ = renamex_np(a, b, UInt32(RENAME_SWAP)) }
        func read(_ folder: String, swapping: Bool) -> AdminScript.PlannedFolder.Read {
            AdminScript.PlannedFolder.read(folder, item: "item", planning: planning, afterOpen: swapping ? swap : {})
        }
        func found(_ identity: ItemIdentity, writable: Bool, item: ItemIdentity?) -> AdminScript.PlannedFolder.Read {
            .found(AdminScript.PlannedFolder(identity: identity, userCanWrite: writable, rootOnlyChain: true), item: item)
        }
        // The writable folder is opened, then the locked one takes its place.
        #expect(read(a, swapping: true) == found(writable, writable: true, item: writableItem))
        #expect(ItemIdentity.of(place) == readOnly)
        // Now the locked one is there: it is opened, then the writable one takes its place again.
        #expect(read(a, swapping: true) == found(readOnly, writable: false, item: readOnlyItem))
        #expect(ItemIdentity.of(place) == writable)
        // Without a swap: the same answers. A missing item is nil; `locked` counts as not writable.
        #expect(read(b, swapping: false) == found(readOnly, writable: false, item: readOnlyItem))
        #expect(AdminScript.PlannedFolder.read(a, item: "none", planning: planning)
            == found(writable, writable: true, item: nil))
        var locking = planning
        locking.locked = { $0 == a }
        #expect(AdminScript.PlannedFolder.read(a, item: nil, planning: locking) == found(writable, writable: false, item: nil))
        // Only a real folder is used: a link to one, a file or nothing at all is not.
        let link = sandbox.root.appending(path: "link")
        try fm.createSymbolicLink(atPath: path(link), withDestinationPath: a)
        #expect(AdminScript.PlannedFolder.read(path(link), item: "item", planning: planning) == .unusable)
        #expect(AdminScript.PlannedFolder.read(a + "/item", item: nil, planning: planning) == .unusable)
        #expect(AdminScript.PlannedFolder.read(path(sandbox.root) + "/missing", item: nil, planning: planning) == .missing)
    }

    @Test func theTrashIsTheUsersOrAVolumesTrashForTheUser() throws {
        let sandbox = try TestSandbox()
        let isTrash = AdminPlanning.trash(of: sandbox.environment)
        let root = path(sandbox.root)
        let uid = getuid()
        #expect(isTrash(root + "/home/.Trash"))
        #expect(isTrash(root + "/Volumes/Backup/.Trashes/\(uid)"))
        #expect(!isTrash(root + "/Volumes/Backup/.Trashes/\(uid &+ 1)"))
        #expect(!isTrash(root + "/Volumes/.Trashes/\(uid)"))
        #expect(!isTrash(root + "/Volumes/a/b/.Trashes/\(uid)"))
        #expect(!isTrash(root + "/home/.Trash/inner"))
        #expect(!isTrash(root + "/home"))
        #expect(!isTrash(root + "/Library/.Trash"))
    }

    @Test func quoteEscapesEveryApostropheScalar() {
        let quoted = AdminScript.quote("a'\u{301}b'\u{FE0F}")
        #expect(Array(quoted.unicodeScalars) == Array("'a'\\''\u{301}b'\\''\u{FE0F}'".unicodeScalars))
    }

    // MARK: - Raced by a program running as the user (the reviewer's PoCs, made deterministic)

    /// Runs `script` as the user and returns its output.
    private func output(of script: String) -> String {
        guard case .finished(let output) = UserShell().run(script: script, prompt: "test") else {
            Issue.record("the script did not finish")
            return ""
        }
        return output
    }

    private func q(_ url: URL) -> String {
        AdminScript.quote(path(url))
    }

    /// `script` with `hooks` (sh functions replacing the prelude's) put right after the functions:
    /// what a program running as the user could do at that point.
    private func hooked(_ script: String, _ hooks: [String]) -> String {
        script.replacingOccurrences(of: "\nown_=", with: "\n" + hooks.joined(separator: "\n") + "\nown_=")
    }

    // The hooks below keep these functions exactly as they are and add the other program's action.
    private static let pinBody = #"cd -P -- "$1" 2>/dev/null && [ "$(id_ .)" = "$2" ]"#
    private static let atBody = #"[ -e "$1" ] || [ -L "$1" ]"#
    private static let idBody = #"/usr/bin/stat -f '%d:%i:%u' -- "$1" 2>/dev/null"#
    private static let rnBody =
        #"/bin/zsh -f -c 'zmodload -F zsh/files b:zf_mv && zf_mv -- "$1" "$2"' rn_ "$1" "$2" </dev/null >/dev/null 2>&1"#

    @Test func hooksKeepTheRealFunctions() {
        #expect(AdminScript.prelude.contains("\npin_() { \(Self.pinBody); }\n"))
        #expect(AdminScript.prelude.contains("\nat_() { \(Self.atBody); }\n"))
        #expect(AdminScript.prelude.contains("\nid_() { \(Self.idBody); }\n"))
        #expect(AdminScript.prelude.contains("\nrn_() { \(Self.rnBody); }\n"))
    }

    /// `name` (`pin_` or `at_`, which run in the script's own shell) does `action` on its `nth` call
    /// with `argument`: before its own work, or after it (then only if that succeeded).
    private func on(_ name: String, _ argument: String, nth: Int, after: Bool = false, _ action: String) -> [String] {
        let body = name == "pin_" ? Self.pinBody : Self.atBody
        let counter = "n\(name)"
        let mine = "[ \"$1\" = \(AdminScript.quote(argument)) ] && [ \"$\(counter)\" = \(nth) ]"
        return [
            "\(counter)=0",
            "\(name)() {",
            "  if [ \"$1\" = \(AdminScript.quote(argument)) ]; then \(counter)=$((\(counter) + 1)); fi",
            after ? "  \(body) || return 1" : "  if \(mine); then \(action); fi",
            after ? "  if \(mine); then \(action); fi" : "  \(body)",
            "}",
        ]
    }

    /// `id_` does `action` the first time it reads an item in the bridge called `name` (it runs in
    /// a subshell, so a flag file says it happened).
    private func onBridgeRead(_ name: String, flag: URL, _ action: String) -> [String] {
        [
            "id_() {",
            "  \(Self.idBody)",
            "  case \"$1\" in */.dustling-*/[0-9]*/\(name)) if ! [ -e \(q(flag)) ]; then /usr/bin/touch \(q(flag)); \(action); fi ;; esac",
            "}",
        ]
    }

    /// A move of `sys/x.plist` (6 bytes) into the Trash. `priv` stands for a folder only root can
    /// write: empty and mode 700 (like a fresh private folder), or holding a victim `x.plist` (7 bytes).
    private struct TrashMove {
        let sandbox: TestSandbox
        let source: URL
        let trash: URL
        let realTrash: URL
        let priv: URL
        let flag: URL
        let script: String

        init(victim: Bool) throws {
            sandbox = try TestSandbox()
            source = try sandbox.file("sys/x.plist", bytes: 6)
            trash = sandbox.root.appending(path: "home/.Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            realTrash = sandbox.root.appending(path: "home/Trash-real")
            priv = sandbox.root.appending(path: "priv")
            try FileManager.default.createDirectory(at: priv, withIntermediateDirectories: true)
            if victim { try sandbox.file("priv/x.plist", bytes: 7) }
            _ = chmod(priv.path(percentEncoded: false), 0o700)
            flag = sandbox.root.appending(path: "flag")
            let step = AdminStep(op: .move(from: source, to: trash.appending(path: "x.plist"), bootOutDaemon: false))
            script = AdminScript.make([step], planning: try sandbox.adminPlanning())
        }
    }

    /// The other program's swap: the Trash moved aside and a link to `priv` put in its place.
    private func swapTrash(_ move: TrashMove) -> String {
        "/bin/mv \(q(move.trash)) \(q(move.realTrash)) && /bin/ln -s \(q(move.priv)) \(q(move.trash))"
    }

    @Test func trashSwappedForALinkJustBeforePublishingIsRefused() throws {
        // r3review poc1: the place root puts the item is replaced by a link to a folder only root
        // can write, just before root uses it. Root pins the Trash by identity, so it never
        // publishes through the link; the item goes back where it came from.
        let move = try TrashMove(victim: false)
        let before = tree(move.sandbox)
        let script = hooked(move.script, on("pin_", path(move.trash), nth: 2, swapTrash(move)))
        #expect(output(of: script) == "R\t0\terr\n")
        #expect(tree(move.sandbox) == changed(before, removing: ["home/.Trash"],
                                              adding: ["home/.Trash": -2, "home/Trash-real": -1]))
    }

    @Test func trashRedirectedAfterTheItemWasVerifiedIsRefused() throws {
        // r3review poc3: after root verified the item (in the bridge), the Trash is redirected at a
        // folder holding a same-named file. Root never names a path through the Trash, so the victim
        // is never taken or replaced; the item goes back where it came from.
        let move = try TrashMove(victim: true)
        let before = tree(move.sandbox)
        let script = hooked(move.script, onBridgeRead("x.plist", flag: move.flag, swapTrash(move)))
        #expect(output(of: script) == "R\t0\terr\n")
        #expect(tree(move.sandbox) == changed(before, removing: ["home/.Trash"], adding: [
            "home/.Trash": -2, "home/Trash-real": -1, "flag": 0,
        ]))
        #expect(size(move.priv.appending(path: "x.plist")) == 7)
    }

    @Test func trashSwappedAfterRootPinnedItIsNeverUsed() throws {
        // The same swap once root is in the Trash: the item goes into the folder root is in (the
        // real Trash, wherever it now is). Nothing reaches the link's target.
        let move = try TrashMove(victim: false)
        let before = tree(move.sandbox)
        let script = hooked(move.script, on("pin_", path(move.trash), nth: 2, after: true, swapTrash(move)))
        #expect(output(of: script) == "R\t0\tok\n")
        #expect(tree(move.sandbox) == changed(before, removing: ["home/.Trash", "sys/x.plist"], adding: [
            "home/.Trash": -2, "home/Trash-real": -1, "home/Trash-real/x.plist": 6,
        ]))
    }

    @Test func itemSwappedJustBeforeTheRenameIsNeverTaken() throws {
        // r3review poc4: the source folder is one the user can write (like /Applications for an
        // admin). Just before root's rename, the app is swapped for another program's file. Root
        // finds it isn't the planned item before mv, so it stays where it is; nothing is touched.
        let sandbox = try TestSandbox()
        try sandbox.file("apps/Foo.app/real", bytes: 6)
        let app = sandbox.root.appending(path: "apps/Foo.app")
        let kept = sandbox.root.appending(path: "apps/Foo-kept.app")
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.directory("priv")
        let step = move(app, trash.appending(path: "Foo.app"))
        let script = AdminScript.make([step], planning: try sandbox.adminPlanning())
        let before = tree(sandbox)
        // The first at_ ./Foo.app is the destination check in the Trash; the second is in apps.
        let hooked = hooked(script, on("at_", "./Foo.app", nth: 2,
                                       "/bin/mv \(q(app)) \(q(kept)); /usr/bin/printf attacker > \(q(app))"))
        #expect(output(of: hooked) == "R\t0\terr\n")
        #expect(tree(sandbox) == changed(before, removing: ["apps/Foo.app"], adding: [
            "apps/Foo.app": 8, "apps/Foo-kept.app": -1, "apps/Foo-kept.app/real": 6,
        ]))
    }

    @Test func publishingBlockedPutsTheItemBack() throws {
        // Something takes the item's name in the Trash after root checked it was free: mv -n
        // doesn't publish, and the item goes back to its folder.
        let move = try TrashMove(victim: false)
        let before = tree(move.sandbox)
        let script = hooked(move.script, onBridgeRead(
            "x.plist", flag: move.flag, "/usr/bin/printf blocked > \(q(move.trash.appending(path: "x.plist")))"))
        #expect(output(of: script) == "R\t0\terr\n")
        #expect(tree(move.sandbox) == changed(before, adding: ["home/.Trash/x.plist": 7, "flag": 0]))
    }

    @Test func failedMoveLeavesNothingInTheBridge() throws {
        // The source vanishes just before root's rename: nothing reaches the bridge, and the step's
        // bridge folder and the bridge itself are removed.
        let move = try TrashMove(victim: false)
        let script = hooked(move.script, [
            "nat_=0",
            "at_() {",
            "  if [ \"$1\" = ./x.plist ]; then nat_=$((nat_ + 1)); fi",
            "  if [ \"$1\" = ./x.plist ] && [ \"$nat_\" = 2 ]; then /bin/rm -f \(q(move.source)); return 0; fi",
            "  \(Self.atBody)",
            "}",
        ])
        #expect(output(of: script) == "R\t0\terr\n")
        #expect(contents(move.trash).isEmpty)
        #expect(contents(move.sandbox.bridges).isEmpty)
    }

    // MARK: - Renames never copy (the reviewer's r5x and r7rev)

    /// `id_` does `action` the first time it reads `argument` (it runs in a subshell, so a flag file
    /// says it happened): before reading it, or right after (then the read sees the old entry).
    private func onRead(_ argument: String, flag: URL, after: Bool = false, _ action: String) -> [String] {
        let once = "if [ \"$1\" = \(AdminScript.quote(argument)) ] && ! [ -e \(q(flag)) ]; then "
            + "/usr/bin/touch \(q(flag)); \(action); fi"
        return ["id_() {", "  \(after ? Self.idBody : once)", "  \(after ? once : Self.idBody)", "}"]
    }

    /// Hooks writing every rename of the functions (`rn_`, and `/bin/mv` inside the bridge) to `log`,
    /// one call per line, before it runs.
    private func loggingRenames(_ script: String, to log: URL) -> String {
        let prelude = AdminScript.prelude
        #expect(script.hasPrefix(prelude))
        return hooked(prelude.replacingOccurrences(of: "/bin/mv ", with: "mvlog_ ") + script.dropFirst(prelude.count), [
            "mvlog_() { /usr/bin/printf 'mv %s\\n' \"$*\" >> \(q(log)); /bin/mv \"$@\"; }",
            "rn_() { /usr/bin/printf 'rn %s\\n' \"$*\" >> \(q(log)); \(Self.rnBody); }",
        ])
    }

    /// `script` with root's rename out of the pinned folder making a copy instead, as `/bin/mv` did
    /// when rename(2) failed with EXDEV (`cp -PRp` into the bridge, then `rm -rf` of the source; as
    /// root, owner and setuid kept). rn_ can't do that; this checks the rule behind it: what lands in
    /// the bridge as a new inode never leaves it. `only` limits it to one step.
    private func copyingInsteadOfRenaming(_ script: String, only step: Int? = nil) -> String {
        let take = #"rn_ "./$3" "$k_""#
        #expect(script.components(separatedBy: take).count == 2)
        let others = step.map { #"if [ "$i_" != \#($0) ]; then rn_ "$1" "$2"; return; fi; "# } ?? ""
        return hooked(script.replacingOccurrences(of: take, with: #"exdev_ "./$3" "$k_""#), [
            #"exdev_() { "# + others + #"/bin/cp -PRp -- "$1" "$2/" && /bin/rm -rf -- "$1"; }"#,
        ])
    }

    /// Hooks making the renames numbered in `failing` (1 = the take, 2 = publishing, 3 = giving back,
    /// for a move) fail the way rn_ fails across volumes: nothing done, status 1.
    private func failingRenames(_ failing: [Int]) -> [String] {
        [
            "nrn_=0",
            "rn_() {",
            "  nrn_=$((nrn_ + 1))",
            "  case ' \(failing.map(String.init).joined(separator: " ")) ' in *\" $nrn_ \"*) return 1 ;; esac",
            "  \(Self.rnBody)",
            "}",
        ]
    }

    /// The one bridge left in `sandbox` (a step held something), or fails the test.
    private func heldBridge(_ sandbox: TestSandbox) throws -> String {
        let left = contents(sandbox.bridges)
        #expect(left.count == 1, "\(left)")
        return path(sandbox.bridges) + "/" + (try #require(left.first))
    }

    private func held(in bridge: String) -> AdminStepResult {
        .notDone(reason: "Something changed while it was moving, so Dustling stopped. It is untouched in \(bridge).")
    }

    private let movedAway = AdminStepResult.notDone(
        reason: "Something changed while it was moving, so Dustling stopped. Another program may have moved your item.")

    @Test func aCopyMadeInsteadOfTheRenameNeverLeavesTheBridge() throws {
        // A copy is a new inode. It is never given back or published, never deleted, and the step
        // doesn't call it the user's item. Shown for a move into the Trash, a Put back and a delete.
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.file("Library/Caches/app/Contents/MacOS/tool", bytes: 6)
        let app = sandbox.root.appending(path: "Library/Caches/app")
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let doomed = try sandbox.file("home/.Trash/old.log", bytes: 5)
        let steps = [
            move(app, trash.appending(path: "app")),
            try putBackStep(trashed, into: folder),
            AdminStep(op: .delete(doomed)),
        ]
        let planned = try [app, trashed, doomed].map { try #require(ItemIdentity.of($0)) }
        let out = output(of: copyingInsteadOfRenaming(AdminScript.make(steps, planning: try sandbox.adminPlanning())))
        let bridge = try heldBridge(sandbox)
        #expect(out == "R\t0\theld_other\nR\t1\theld_other\nR\t2\theld_other\n")
        #expect(AdminScript.parse(out, count: 3) == Array(repeating: movedAway, count: 3))
        // The copies stay in the bridge, untouched: new inodes, same content.
        let copies = ["0/app", "1/helper", "2/old.log"].map { URL(filePath: bridge + "/" + $0) }
        for (copy, original) in zip(copies, planned) {
            #expect(ItemIdentity.of(copy).map { $0.inode != original.inode } == true)
        }
        #expect(size(copies[0].appending(path: "Contents/MacOS/tool")) == 6)
        #expect(size(copies[1]) == 4)
        #expect(size(copies[2]) == 5)
        // Nothing handed back, published or deleted.
        #expect(contents(trash).isEmpty)
        #expect(contents(sandbox.root.appending(path: "Library/Caches")).isEmpty)
        #expect(contents(folder).isEmpty)
    }

    @Test func aCopyInTheBridgeIsNeverPublishedOrGivenBack() throws {
        // Publishing and giving back check the inode too: here what sits in the bridge becomes a
        // copy right before publishing. It stays in the bridge; the Trash and sys get nothing.
        let move = try TrashMove(victim: false)
        let copy = #"/bin/cp -p "$k_/x.plist" "$k_/c" && /bin/rm -f "$k_/x.plist" && /bin/mv "$k_/c" "$k_/x.plist""#
        let out = output(of: hooked(move.script, on("pin_", path(move.trash), nth: 2, copy)))
        let bridge = try heldBridge(move.sandbox)
        #expect(out == "R\t0\theld_other\n")
        #expect(size(URL(filePath: bridge + "/0/x.plist")) == 6)
        #expect(contents(move.trash).isEmpty)
        #expect(contents(move.source.deletingLastPathComponent()).isEmpty)
    }

    @Test func anItemThatChangedRightBeforeTheRenameIsNeverRenamed() throws {
        // Root reads the entry right before its rename. Here another program replaces it at that
        // very moment (another inode; a disk image mounted there would be another volume): it is
        // never renamed, nothing reaches the bridge, and the other file stays where it is.
        let move = try TrashMove(victim: false)
        let log = move.sandbox.root.appending(path: "rename.log")
        let kept = move.sandbox.root.appending(path: "kept.plist")
        let swap = "/bin/mv \(q(move.source)) \(q(kept)); /usr/bin/printf attacker > \(q(move.source))"
        let script = loggingRenames(hooked(move.script, onRead("./x.plist", flag: move.flag, swap)), to: log)
        #expect(output(of: script) == "R\t0\terr\n")
        #expect(!exists(log))
        #expect(size(move.source) == 8)
        #expect(size(kept) == 6)
        #expect(contents(move.trash).isEmpty)
        #expect(contents(move.sandbox.bridges).isEmpty)
    }

    @Test func anItemSwappedBetweenTheCheckAndTheRenameStaysInTheBridge() throws {
        // The residual race: the entry changes after root's check and before its rename. What root
        // took isn't the planned item, so it stays in the bridge (even though its name is free to
        // go back to), and the step says another program may have moved the user's item, which is
        // never touched.
        let move = try TrashMove(victim: false)
        let log = move.sandbox.root.appending(path: "rename.log")
        let kept = move.sandbox.root.appending(path: "kept.plist")
        let swap = "/bin/mv \(q(move.source)) \(q(kept)); /usr/bin/printf attacker > \(q(move.source))"
        let script = loggingRenames(hooked(move.script, onRead("./x.plist", flag: move.flag, after: true, swap)), to: log)
        let out = output(of: script)
        let bridge = try heldBridge(move.sandbox)
        #expect(out == "R\t0\theld_other\n")
        #expect(AdminScript.parse(out, count: 1) == [movedAway])
        // One rename: the take. Nothing was given back or published.
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(calls.count == 1 && calls.first?.hasPrefix("rn ./x.plist ") == true, "\(calls)")
        #expect(size(URL(filePath: bridge + "/0/x.plist")) == 8)
        #expect(size(kept) == 6)
        #expect(contents(move.source.deletingLastPathComponent()).isEmpty)
        #expect(contents(move.trash).isEmpty)
    }

    @Test func thePlannedItemIsHeldWhenItCanGoNeitherOnNorBack() throws {
        // Right after root verified the item in the bridge, its name is taken both in the Trash and
        // in sys: it can't be published or given back, so it stays in the bridge, and the step says
        // where (it used to be a plain err).
        let move = try TrashMove(victim: false)
        let planned = try #require(ItemIdentity.of(move.source))
        let block = "/usr/bin/printf blocked > \(q(move.trash.appending(path: "x.plist"))); "
            + "/usr/bin/printf blocked > \(q(move.source))"
        let out = output(of: hooked(move.script, onBridgeRead("x.plist", flag: move.flag, block)))
        let bridge = try heldBridge(move.sandbox)
        #expect(out == "B\t\(bridge)\nR\t0\theld\n")
        #expect(AdminScript.parse(out, count: 1) == [held(in: bridge)])
        #expect(ItemIdentity.of(URL(filePath: bridge + "/0/x.plist")) == planned)
        #expect(size(move.trash.appending(path: "x.plist")) == 7)
        #expect(size(move.source) == 7)
    }

    @Test func theBridgePathIsPrintedOnceAndOnlyForThePlannedItem() throws {
        // a moves; b and c are held (their names are taken on both sides); d's take makes a copy.
        // One B line, before the first held step; d's reason doesn't call the copy the user's item.
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let library = sandbox.root.appending(path: "Library")
        let items = try ["a", "b", "c", "d"].enumerated().map { try sandbox.file("Library/\($1)", bytes: $0 + 1) }
        let flags = try sandbox.directory("flags")
        let script = AdminScript.make(items.map { move($0, trash.appending(path: $0.lastPathComponent)) },
                                      planning: try sandbox.adminPlanning())
        let block = [
            "id_() {",
            "  \(Self.idBody)",
            "  case \"$1\" in */.dustling-*/[0-9]*/b|*/.dustling-*/[0-9]*/c)",
            "    n_=\"${1##*/}\"",
            "    if ! [ -e \(q(flags))/\"$n_\" ]; then /usr/bin/touch \(q(flags))/\"$n_\"; "
                + "/usr/bin/printf blocked > \(q(trash))/\"$n_\"; /usr/bin/printf blocked > \(q(library))/\"$n_\"; fi ;;",
            "  esac",
            "}",
        ]
        let out = output(of: copyingInsteadOfRenaming(hooked(script, block), only: 3))
        let bridge = try heldBridge(sandbox)
        #expect(out == "R\t0\tok\nB\t\(bridge)\nR\t1\theld\nR\t2\theld\nR\t3\theld_other\n")
        #expect(AdminScript.parse(out, count: 4) == [.done, held(in: bridge), held(in: bridge), movedAway])
        #expect(size(trash.appending(path: "a")) == 1)
        #expect(Set(contents(URL(filePath: bridge))) == ["1", "2", "3"])
    }

    @Test func aRenameThatFailsAcrossVolumesCopiesNothing() throws {
        // rn_ only renames: across volumes (a disk image mounted at the target, or the source
        // replaced by one) it fails and does nothing. Whatever rename fails, nothing is copied
        // anywhere; the item ends up where it was or, untouched, in the bridge.
        func attempt(failing: [Int]) throws -> (output: String, move: TrashMove, before: [String: Int64]) {
            let move = try TrashMove(victim: false)
            let before = tree(move.sandbox)
            return (output(of: hooked(move.script, failingRenames(failing))), move, before)
        }
        // The take fails: nothing moved at all.
        let take = try attempt(failing: [1])
        #expect(take.output == "R\t0\terr\n")
        #expect(tree(take.move.sandbox) == take.before)
        // Publishing fails: the item is given back.
        let publish = try attempt(failing: [2])
        #expect(publish.output == "R\t0\terr\n")
        #expect(tree(publish.move.sandbox) == publish.before)
        // Publishing and giving back fail: the planned item stays in the bridge, untouched.
        let both = try attempt(failing: [2, 3])
        let bridge = try heldBridge(both.move.sandbox)
        #expect(both.output == "B\t\(bridge)\nR\t0\theld\n")
        let relative = String(bridge.dropFirst(path(both.move.sandbox.root).count + 1))
        #expect(tree(both.move.sandbox) == changed(both.before, removing: ["sys/x.plist"], adding: [
            relative: -1, relative + "/0": -1, relative + "/0/x.plist": 6,
        ]))
    }

    @Test func aLinkPutAtTheNameRightBeforeTheRenameIsReplacedNotFollowed() throws {
        // r7rev: right after root found the name free, another program puts a link to a folder
        // there. /bin/mv's copy would have gone into that folder; the rename replaces the link
        // itself. Shown when publishing into the Trash, and when giving back to sys.
        func run(blockPublishing: Bool) throws -> (output: String, move: TrashMove, planned: ItemIdentity) {
            let move = try TrashMove(victim: true)
            let planned = try #require(ItemIdentity.of(move.source))
            // at_ ./x.plist: 1 the destination check, 2 the take, 3 publishing, 4 giving back.
            let linkAt = blockPublishing ? 4 : 3
            let hooks = [
                "nat_=0",
                "at_() {",
                "  if [ \"$1\" = ./x.plist ]; then nat_=$((nat_ + 1)); fi",
                blockPublishing
                    ? "  if [ \"$1\" = ./x.plist ] && [ \"$nat_\" = 3 ]; then /usr/bin/printf blocker > ./x.plist; fi"
                    : "",
                "  \(Self.atBody); r_=$?",
                "  if [ \"$1\" = ./x.plist ] && [ \"$nat_\" = \(linkAt) ]; then /bin/ln -s \(q(move.priv)) ./x.plist; fi",
                "  return $r_",
                "}",
            ]
            return (output(of: hooked(move.script, hooks)), move, planned)
        }
        let published = try run(blockPublishing: false)
        #expect(published.output == "R\t0\tok\n")
        #expect(ItemIdentity.of(published.move.trash.appending(path: "x.plist")) == published.planned)
        #expect(contents(published.move.priv) == ["x.plist"])
        #expect(size(published.move.priv.appending(path: "x.plist")) == 7)
        let givenBack = try run(blockPublishing: true)
        #expect(givenBack.output == "R\t0\terr\n")
        #expect(ItemIdentity.of(givenBack.move.source) == givenBack.planned)
        #expect(size(givenBack.move.trash.appending(path: "x.plist")) == 7)
        #expect(contents(givenBack.move.priv) == ["x.plist"])
        #expect(size(givenBack.move.priv.appending(path: "x.plist")) == 7)
    }

    @Test func rnIsARenameOntoAFolderOnly() throws {
        // The real rn_, as the script runs it. Onto a folder: the item keeps its name there. A link
        // already at that name is replaced, never followed; a directory there is never replaced; a
        // link as the source moves as itself.
        let sandbox = try TestSandbox()
        let a = try sandbox.directory("a")
        let b = try sandbox.directory("b")
        let target = try sandbox.directory("target")
        try sandbox.file("a/x", bytes: 1)
        try sandbox.file("a/y", bytes: 2)
        try sandbox.file("a/dir", bytes: 3)
        try sandbox.directory("b/dir")
        try fm.createSymbolicLink(atPath: path(b) + "/y", withDestinationPath: path(target))
        try fm.createSymbolicLink(atPath: path(a) + "/ln", withDestinationPath: path(target))
        let script = AdminScript.prelude + "\ncd -P -- \(q(b))\n"
            + ["x", "y", "dir", "ln"].map { "rn_ \(AdminScript.quote(path(a) + "/" + $0)) .\n" }.joined()
        #expect(output(of: script) == "")
        #expect(size(b.appending(path: "x")) == 1)
        #expect(size(b.appending(path: "y")) == 2)
        #expect((try? fm.destinationOfSymbolicLink(atPath: path(b) + "/ln")) == path(target))
        #expect(size(a.appending(path: "dir")) == 3)
        #expect(contents(b.appending(path: "dir")).isEmpty)
        #expect(contents(target).isEmpty)
        #expect(contents(a) == ["dir"])
    }

    @Test func rnReadsNoStartupFilesOrModulePathFromTheEnvironment() throws {
        // zsh -f skips ~/.zshenv and the rest (control: without -f it reads ZDOTDIR's .zshenv); the
        // module path from the environment is ignored, so zsh/files comes from the system.
        let sandbox = try TestSandbox()
        let dot = try sandbox.directory("dot")
        let marker = sandbox.root.appending(path: "read")
        try Data("/usr/bin/touch \(q(marker))\n".utf8).write(to: dot.appending(path: ".zshenv"))
        try Data("/usr/bin/touch \(q(marker))\n".utf8).write(to: dot.appending(path: ".zshrc"))
        let environment = ["ZDOTDIR": path(dot), "HOME": path(dot), "MODULE_PATH": path(dot), "PATH": "/usr/bin:/bin"]
        let runner = ProcessCommandRunner()
        let quiet = try runner.run(
            "/bin/zsh", ["-f", "-c", "zmodload -F zsh/files b:zf_mv && print -r -- $module_path"], environment: environment)
        #expect(quiet.status == 0)
        #expect(quiet.stdout.hasPrefix("/usr/lib/zsh/"), "\(quiet.stdout)")
        #expect(!exists(marker))
        let control = try runner.run("/bin/zsh", ["-c", "true"], environment: environment)
        #expect(control.status == 0)
        #expect(exists(marker))
        #expect(Self.rnBody.hasPrefix("/bin/zsh -f -c "))
    }

    @Test func rnWorksInOsascriptsEnvironment() throws {
        // osascript runs the script with a minimal environment (only PATH); zsh still loads its module.
        let sandbox = try TestSandbox()
        try sandbox.file("a/x", bytes: 4)
        let b = try sandbox.directory("b")
        let script = AdminScript.prelude + "\ncd -P -- \(q(b)) && rn_ \(AdminScript.quote(path(sandbox.root) + "/a/x")) . "
            + "&& /usr/bin/printf moved\n"
        #expect(OsascriptAdminShell(privileged: false).run(script: script, prompt: "x") == .finished(output: "moved"))
        #expect(size(b.appending(path: "x")) == 4)
    }

    // MARK: - The bridge

    @Test func bridgeThatIsNotFreshAndPrivateFailsEveryStep() throws {
        func attempt(_ make: (TestSandbox, [AdminStep]) throws -> String) throws {
            let sandbox = try TestSandbox()
            let trash = try sandbox.directory("home/.Trash")
            let item = try sandbox.file("Library/Caches/a", bytes: 4)
            try sandbox.file("home/.Trash/b", bytes: 5)
            let steps = [move(item, trash.appending(path: "a")), AdminStep(op: .delete(trash.appending(path: "b")))]
            let script = try make(sandbox, steps)
            let before = tree(sandbox)
            #expect(output(of: script) == "R\t0\terr\nR\t1\terr\n")
            #expect(tree(sandbox) == before)
            _ = chmod(path(sandbox.bridges), 0o755)
            #expect(contents(sandbox.bridges).isEmpty)
        }
        // Not owned by the one who must own it (root, in the app).
        try attempt { sandbox, steps in
            AdminScript.make(steps, planning: try sandbox.adminPlanning(bridgeOwner: getuid() &+ 1))
        }
        // Not on the volume planning saw (as if it landed on another one when run).
        try attempt { sandbox, steps in
            let planning = try sandbox.adminPlanning()
            let real = try #require(AdminScript.PlannedBridge(planning))
            let line = "\nbridge_ \(AdminScript.quote(real.parent)) \(real.device)\n"
            let script = AdminScript.make(steps, planning: planning)
            #expect(script.contains(line))
            return script.replacingOccurrences(
                of: line, with: "\nbridge_ \(AdminScript.quote(real.parent)) \(real.device &+ 1)\n")
        }
        // Can't be made at all.
        try attempt { sandbox, steps in
            let planning = try sandbox.adminPlanning()
            let script = AdminScript.make(steps, planning: planning)
            #expect(chmod(path(sandbox.bridges), 0o555) == 0)
            return script
        }
    }

    @Test func bridgeLosesInheritedPermissions() throws {
        // Inheritable ACL entries on the bridge's parent would reach the bridge; root removes them.
        let move = try TrashMove(victim: false)
        let user = String(cString: try #require(getpwuid(getuid())).pointee.pw_name)
        let rights = "\(user) allow list,add_file,search,add_subdirectory,delete_child,writesecurity,chown,"
            + "file_inherit,directory_inherit"
        #expect(try ProcessCommandRunner().run("/bin/chmod", ["+a", rights, path(move.sandbox.bridges)]).status == 0)
        // Control: a folder made there inherits the entry.
        let control = move.sandbox.bridges.appending(path: "control")
        try fm.createDirectory(at: control, withIntermediateDirectories: false)
        #expect(try ProcessCommandRunner().run("/bin/ls", ["-led", path(control)]).stdout.contains("inherited allow"))
        try fm.removeItem(at: control)
        let record = move.sandbox.root.appending(path: "bridge.txt")
        let script = hooked(move.script, ["boot_() { /bin/ls -led \"$br_\" > \(q(record)); }"])
        #expect(output(of: script) == "R\t0\tok\n")
        let listing = try String(contentsOf: record, encoding: .utf8)
        #expect(listing.hasPrefix("drwx------"), "\(listing)")
        #expect(listing.split(separator: "\n").count == 1, "\(listing)")
        #expect(size(move.trash.appending(path: "x.plist")) == 6)
        #expect(contents(move.sandbox.bridges).isEmpty)
    }

    // MARK: - Put back

    private func putBackStep(_ trashed: URL, into folder: URL) throws -> AdminStep {
        AdminStep(op: .move(from: trashed, to: folder.appending(path: trashed.lastPathComponent), bootOutDaemon: false),
                  expectedSource: try #require(ItemIdentity.of(trashed)))
    }

    @Test func putBackGoesThroughTheBridge() throws {
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/com.x.plist", bytes: 4)
        let folder = try sandbox.directory("Library/LaunchDaemons")
        let recorded = try #require(ItemIdentity.of(trashed))
        let planning = try sandbox.adminPlanning(locked: { $0.hasSuffix("/LaunchDaemons") })
        let script = AdminScript.make([try putBackStep(trashed, into: folder)], planning: planning)
        #expect(script.contains("\nmove_ 0 - 0 \(recorded.stamp) 1 '"))
        #expect(AdminScript.parse(output(of: script), count: 1) == [.done])
        #expect(ItemIdentity.of(folder.appending(path: "com.x.plist")) == recorded)
        #expect(!exists(trashed))
        #expect(contents(sandbox.bridges).isEmpty)
    }

    /// Puts back `helper` from the Trash into a folder; another program swaps its own file in at
    /// `helper`: `early`, before root's last check of the entry (so mv never sees it), or else right
    /// after that check, before the rename.
    private func putBackWithSwap(early: Bool) throws
        -> (output: String, sandbox: TestSandbox, folder: URL, trashed: URL, kept: URL)
    {
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let kept = sandbox.root.appending(path: "home/.Trash/kept")
        let impostor = try sandbox.file("impostor", bytes: 9)
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let script = AdminScript.make([try putBackStep(trashed, into: folder)], planning: try sandbox.adminPlanning())
        let swap = "/bin/mv \(q(trashed)) \(q(kept)); /bin/cp \(q(impostor)) \(q(trashed))"
        let flag = sandbox.root.appending(path: "flag")
        return (output(of: hooked(script, onRead("./helper", flag: flag, after: !early, swap))), sandbox, folder,
                trashed, kept)
    }

    @Test func swappedSourceIsNeverTaken() throws {
        let swap = try putBackWithSwap(early: true)
        #expect(swap.output == "R\t0\terr\n")
        #expect(contents(swap.folder).isEmpty)
        #expect(size(swap.trashed) == 9)
        #expect(size(swap.kept) == 4)
        #expect(contents(swap.sandbox.bridges).isEmpty)
    }

    @Test func sourceSwappedAfterTheCheckStaysInTheBridge() throws {
        // The impostor reached the bridge: it is never published, and never given back either (only
        // the inode root checked may leave the bridge), though its name in the Trash is free. The
        // step is held_other (it isn't the user's item) and the bridge is left (never rm -rf'ed).
        let swap = try putBackWithSwap(early: false)
        let bridge = try heldBridge(swap.sandbox)
        #expect(swap.output == "R\t0\theld_other\n")
        #expect(contents(swap.folder).isEmpty)
        #expect(!exists(swap.trashed))
        #expect(size(swap.kept) == 4)
        #expect(size(URL(filePath: bridge + "/0/helper")) == 9)
    }

    @Test func trashSwappedJustBeforeTheRenameIsNeverUsed() throws {
        // Right before root's rename out of the Trash, the Trash is swapped for a link to a folder
        // holding a same-named item. Root takes ./helper of the Trash it pinned: the recorded item;
        // the other item is never touched.
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let victim = try sandbox.file("elsewhere/helper", bytes: 6)
        let trash = sandbox.root.appending(path: "home/.Trash")
        let realTrash = sandbox.root.appending(path: "home/Trash-real")
        let elsewhere = sandbox.root.appending(path: "elsewhere")
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let recorded = try #require(ItemIdentity.of(trashed))
        let script = hooked(
            AdminScript.make([try putBackStep(trashed, into: folder)], planning: try sandbox.adminPlanning()),
            on("at_", "./helper", nth: 2, "/bin/mv \(q(trash)) \(q(realTrash)) && /bin/ln -s \(q(elsewhere)) \(q(trash))"))
        #expect(AdminScript.parse(output(of: script), count: 1) == [.done])
        #expect((try? fm.destinationOfSymbolicLink(atPath: path(trash))) != nil)
        #expect(ItemIdentity.of(folder.appending(path: "helper")) == recorded)
        #expect(size(victim) == 6)
        #expect(!exists(realTrash.appending(path: "helper")))
    }

    // MARK: - Root-only chains

    @Test func rootOnlyChainIsTheUsersView() throws {
        #expect(RootOnlyChain.contains("/"))
        #expect(RootOnlyChain.contains("/Library"))
        #expect(RootOnlyChain.contains("/Library/LaunchDaemons"))
        // Sticky, but anyone can add entries.
        #expect(!RootOnlyChain.contains("/Library/Caches"))
        #expect(!RootOnlyChain.contains("/private/tmp"))
        // A link in the chain.
        #expect(!RootOnlyChain.contains("/tmp"))
        // Group-writable by a group the user is in (admins can write /Applications).
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        if count > 0, groups.prefix(Int(count)).contains(80) {
            #expect(!RootOnlyChain.contains("/Applications"))
        }
        let sandbox = try TestSandbox()
        let folder = try sandbox.directory("Library/LaunchDaemons")
        #expect(!RootOnlyChain.contains(path(folder)))
        #expect(!RootOnlyChain.isRootOnly(path(folder)))
        // The owner can always give themselves write permission again.
        #expect(chmod(path(folder), 0o555) == 0)
        defer { _ = chmod(path(folder), 0o755) }
        #expect(!RootOnlyChain.isRootOnly(path(folder)))
        let file = try sandbox.file("Library/file")
        #expect(!RootOnlyChain.isRootOnly(path(file)))
        #expect(!RootOnlyChain.contains("Library/LaunchDaemons"))
        #expect(!RootOnlyChain.contains("/nonexistent-dustling-folder"))
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
        let results = try run([
            AdminStep(op: .delete(tree), dependsOn: nil),
            AdminStep(op: .delete(missing), dependsOn: nil),
        ], in: sandbox)
        #expect(results == [.done, .done])
        #expect(!exists(tree))
        #expect(size(outside) == 8)
    }

    @Test func aDeleteThatLeavesPartOfTheItemSaysWhereTheRestIs() throws {
        // rm stops at what it can't remove (here a folder the user, running the script, can't
        // change; for root, a file macOS protects). The rest is no longer in the Trash: it is in
        // the bridge, and the reason names it.
        let sandbox = try TestSandbox()
        let item = try sandbox.directory("home/.Trash/Stubborn")
        try sandbox.file("home/.Trash/Stubborn/gone.bin", bytes: 4)
        let locked = try sandbox.directory("home/.Trash/Stubborn/locked")
        try sandbox.file("home/.Trash/Stubborn/locked/kept.bin", bytes: 5)
        FolderMode.lock(locked)
        let script = AdminScript.make([AdminStep(op: .delete(item))], planning: try sandbox.adminPlanning())
        let out = output(of: script)
        let bridge = try heldBridge(sandbox)
        defer { FolderMode.unlock(URL(filePath: bridge + "/0/Stubborn/locked")) }
        #expect(out == "B\t\(bridge)\nR\t0\tpartial\n")
        #expect(AdminScript.parse(out, count: 1)
            == [.notDone(reason: "macOS refused to delete part of it, even with your password. What is left is in \(bridge).")])
        #expect(!exists(item))
        #expect(size(URL(filePath: bridge + "/0/Stubborn/locked/kept.bin")) == 5)
        #expect(!exists(URL(filePath: bridge + "/0/Stubborn/gone.bin")))
    }

    @Test func deleteOfAnItemSwappedJustBeforeTheRenameDeletesNothing() throws {
        // Just before root takes the item out of the Trash, it is moved aside and another put in
        // its place. Root finds that isn't the planned item and gives it back: nothing is deleted.
        let sandbox = try TestSandbox()
        let item = try sandbox.file("home/.Trash/old.log", bytes: 4)
        let kept = sandbox.root.appending(path: "home/.Trash/kept.log")
        let other = try sandbox.file("home/Documents/precious", bytes: 9)
        let script = AdminScript.make([AdminStep(op: .delete(item))], planning: try sandbox.adminPlanning())
        let before = tree(sandbox)
        let hooked = hooked(script, on("at_", "./old.log", nth: 1, "/bin/mv \(q(item)) \(q(kept)); /bin/mv \(q(other)) \(q(item))"))
        #expect(output(of: hooked) == "R\t0\terr\n")
        #expect(tree(sandbox) == changed(before, removing: ["home/Documents/precious"], adding: [
            "home/.Trash/old.log": 9, "home/.Trash/kept.log": 4,
        ]))
    }

    @Test func somethingWhereNothingWasPlannedIsNeverDeleted() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let late = trash.appending(path: "late")
        let shell = UserShell(beforeRun: { try Data(count: 3).write(to: late) })
        let script = AdminScript.make([AdminStep(op: .delete(late))], planning: try sandbox.adminPlanning())
        guard case .finished(let output) = shell.run(script: script, prompt: "p") else {
            Issue.record("the script did not finish")
            return
        }
        #expect(output == "R\t0\terr\n")
        #expect(size(late) == 3)
    }

    @Test func trailingSlashNeverFollowsALink() throws {
        let sandbox = try TestSandbox()
        let target = try sandbox.file("outside/keep.bin", bytes: 8)
        let link = sandbox.root.appending(path: "home/.Trash/link")
        try sandbox.directory("home/.Trash")
        try fm.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        let withSlash = URL(filePath: path(link) + "/", directoryHint: .isDirectory)
        #expect(withSlash.path(percentEncoded: false).hasSuffix("/"))
        let results = try run([AdminStep(op: .delete(withSlash), dependsOn: nil)], in: sandbox)
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
            #expect(!script.contains("\nbridge_ "))
        }
    }

    // MARK: - Hostile names

    @Test func quotingSurvivesHostileNames() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        let daemons = try sandbox.directory("Library/LaunchDaemons")
        _ = try sandbox.adminPlanning()
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
        let returning = "r'\u{301};echo z;'s"
        try sandbox.file("Library/\(names[0])/Contents/Info.plist", bytes: 5)
        for (offset, name) in names.enumerated().dropFirst() {
            try sandbox.file("Library/\(name)", bytes: 10 + offset)
        }
        try sandbox.file("home/.Trash/\(doomed)", bytes: 3)
        try sandbox.file("home/.Trash/\(returning)", bytes: 2)
        try sandbox.file("Library/bystander.txt", bytes: 9)
        try sandbox.file("home/keep.txt", bytes: 9)
        let before = try snapshot(sandbox.root)

        let steps = names.map { name in
            move(sandbox.root.appending(path: "Library/\(name)"), trash.appending(path: name))
        } + [
            AdminStep(op: .delete(trash.appending(path: doomed))),
            try putBackStep(trash.appending(path: returning), into: daemons),
        ]
        let results = try run(steps, in: sandbox)
        #expect(results == Array(repeating: .done, count: names.count + 2))

        var expected = Set<String>()
        for path in before where path != "home/.Trash/\(doomed)" {
            var renamed = path
            for name in names {
                let from = "Library/\(name)"
                if path == from || path.hasPrefix(from + "/") {
                    renamed = "home/.Trash/\(name)" + path.dropFirst(from.count)
                }
            }
            if path == "home/.Trash/\(returning)" { renamed = "Library/LaunchDaemons/\(returning)" }
            expected.insert(renamed)
        }
        #expect(try snapshot(sandbox.root) == expected)
        #expect(size(trash.appending(path: "\(names[0])/Contents/Info.plist")) == 5)
        for (offset, name) in names.enumerated().dropFirst() {
            #expect(size(trash.appending(path: name)) == Int64(10 + offset), "\(name.debugDescription)")
        }
        #expect(!exists(trash.appending(path: doomed)))
        #expect(size(daemons.appending(path: returning)) == 2)
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
        let output = "R\t0\tok\nR\t1\tgone\nR\t2\tskip\nR\t3\texists\nR\t4\terr\nR\t5\tunsafe\n"
            + "R\t6\tunsafe_putback\nB\t/Library/.dustling-Ab12Cd34\nR\t7\theld\nR\t8\theld_other\nR\t9\tpartial\n"
        #expect(AdminScript.parse(output, count: 10) == [
            .done,
            .notDone(reason: "already gone"),
            .notDone(reason: "kept because the app itself was not removed"),
            .notDone(reason: "something with the same name is already there"),
            .notDone(reason: "macOS refused, even with your password"),
            .notDone(reason: "Dustling can't safely move this with your password. Move it to the Trash in Finder."),
            .notDone(reason: "Dustling can't safely put this back with your password. Use Put Back in Finder."),
            .notDone(reason: "Something changed while it was moving, so Dustling stopped. "
                + "It is untouched in /Library/.dustling-Ab12Cd34."),
            .notDone(reason: "Something changed while it was moving, so Dustling stopped. "
                + "Another program may have moved your item."),
            .notDone(reason: "macOS refused to delete part of it, even with your password. "
                + "What is left is in /Library/.dustling-Ab12Cd34."),
        ])
        #expect(AdminScript.isKeptAside(AdminScript.heldReason(bridge: "/Library/.dustling-x")))
        #expect(AdminScript.isKeptAside(AdminScript.partlyDeletedReason(bridge: nil)))
        #expect(!AdminScript.isKeptAside(AdminScript.movedAwayReason))
        #expect(!AdminScript.isKeptAside(AdminScript.refusedReason))
    }

    @Test func parseReadsWhereAHeldItemIs() {
        let held = { (place: String) in
            AdminStepResult.notDone(reason: "Something changed while it was moving, so Dustling stopped. It is untouched in \(place).")
        }
        // The B line may come anywhere and is not a step's line; the first one counts.
        #expect(AdminScript.parse("R\t0\theld\nR\t1\tok\nB\t/Library/.dustling-Ab12Cd34\nB\t/elsewhere\n", count: 2)
            == [held("/Library/.dustling-Ab12Cd34"), .done])
        // A path is read whole, spaces and tabs included.
        #expect(AdminScript.parse("B\t/Vol ume/.dustling-x\ty\nR\t0\theld\n", count: 1) == [held("/Vol ume/.dustling-x\ty")])
        // Without it (the script always prints it first) the reason still says where to look.
        #expect(AdminScript.parse("R\t0\theld\nB\t\n", count: 1) == [held("a hidden folder in /Library")])
        // B lines never become results.
        #expect(AdminScript.parse("B\t0\tok\n", count: 1) == [.notDone(reason: "no result")])
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

    @Test func terminateRunningStopsTheOsascriptChildAndEveryLaterRun() throws {
        // Without privileges (no password box): the script sleeps where the box would wait.
        let shell = OsascriptAdminShell(privileged: false)
        final class Outcome: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            var result: AdminShellResult?
        }
        let outcome = Outcome()
        let started = Date()
        Thread.detachNewThread {
            outcome.result = shell.run(script: "/bin/sleep 20; echo done", prompt: "x")
            outcome.done.signal()
        }
        let deadline = Date().addingTimeInterval(10)
        while shell.runningCount == 0, Date() < deadline { usleep(10_000) }
        #expect(shell.runningCount == 1)
        shell.terminateRunning()
        #expect(outcome.done.wait(timeout: .now() + 15) == .success)
        #expect(outcome.result == .failed(reason: OsascriptAdminShell.stoppedReason))
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(shell.runningCount == 0)
        // Nothing starts afterwards (not even for a moment: with privileges a box would flash), on
        // this shell or a copy of it…
        let copy = shell
        #expect(copy.run(script: "echo late", prompt: "x") == .failed(reason: OsascriptAdminShell.stoppedReason))
        #expect(shell.runningCount == 0)
        #expect(shell.startedCount == 1)
        #expect(OsascriptAdminShell.stoppedReason == "Dustling stopped before the password step finished.")
        // …while another shell is unaffected.
        guard case .finished = OsascriptAdminShell(privileged: false).run(script: "echo ok", prompt: "x") else {
            Issue.record("another shell must still run")
            return
        }
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
        // Only the error number at the very end counts. osascript's position prefix is dropped.
        #expect(map(1, "", "0:17: execution error: User canceled.\n") == .failed(reason: "User canceled."))
        #expect(map(1, "", "0:9: syntax error: (-128) in '/x' (-2741)\n")
            == .failed(reason: "(-128) in '/x' (-2741)"))
        #expect(map(1, "", "0:9: execution error: (-1280)\n") == .failed(reason: "(-1280)"))
        #expect(map(1, "", "  0:37: execution error: hi (3)\n") == .failed(reason: "hi (3)"))
        #expect(map(1, "", "sh: 1: no such thing\n") == .failed(reason: "sh: 1: no such thing"))
        #expect(map(1, "", "") == .failed(reason: "osascript stopped with status 1"))
        // macOS turned the password down (three wrong tries, or an account that can't approve it),
        // in any language.
        let refused = AdminShellResult.failed(reason: "Your Mac password wasn't accepted.")
        #expect(map(1, "", "0:2318: execution error: The administrator user name or password was incorrect. (-60007)\n")
            == refused)
        #expect(map(1, "", "0:2318: execution error: Yönetici kullanıcı adı veya parolası yanlış. (-60007)\n") == refused)
        #expect(map(1, "", "0:2318: execution error: Authorization denied. (-60005)\n") == refused)
        #expect(map(1, "", "0:2318: execution error: The authorization was canceled. (-60006)\n") == refused)
        #expect(map(1, "", "0:2318: execution error: Some other failure. (-60008)\n")
            == .failed(reason: "Some other failure. (-60008)"))
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
