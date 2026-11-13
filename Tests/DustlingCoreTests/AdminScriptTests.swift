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
        return AdminScript.make(steps, plans: plans, bridge: planned)
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
        for line in AdminScript.prelude.split(separator: "\n").map(String.init) {
            for tool in ["/bin/mv ", "/bin/rm ", "/bin/mkdir ", "/bin/rmdir ", "/bin/chmod "] {
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
        #expect(script.contains(#"/bin/mv -n -h -- "./$3" "$k_/" >/dev/null 2>&1"#))
        #expect(script.contains(#"/bin/mv -n -h -- "$k_/$3" . >/dev/null 2>&1"#))
        #expect(script.contains(#"/bin/mv -n -h -- "$k_/$dn_" . >/dev/null 2>&1"#))
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
        // Into a folder the user can't write: only with the recorded identity.
        #expect(callLines(text([putBack], destinationWritable: false)).first
            == "move_ 0 - 0 7:99:0 1 '/Users/u/.Trash' 7:41:0 'x' 7:99:0 '/Library' 7:42:501 'x'")
        #expect(callLines(text([unchecked], destinationWritable: false)).first == "report_ 0 unsafe")
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

    @Test func hooksKeepTheRealFunctions() {
        #expect(AdminScript.prelude.contains("\npin_() { \(Self.pinBody); }\n"))
        #expect(AdminScript.prelude.contains("\nat_() { \(Self.atBody); }\n"))
        #expect(AdminScript.prelude.contains("\nid_() { \(Self.idBody); }\n"))
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

    @Test func itemSwappedJustBeforeTheRenameGoesBack() throws {
        // r3review poc4: the source folder is one the user can write (like /Applications for an
        // admin). Just before root's rename, the app is swapped for another program's file. Root
        // finds it isn't the planned item and gives it back; nothing else is touched.
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

    /// Puts back `helper` from the Trash into a folder; just before root's rename out of the Trash,
    /// another file is swapped in at `helper`. With `takeAgain`, the name is taken again while the
    /// impostor is in the bridge.
    private func putBackWithSwap(takeAgain: Bool) throws
        -> (output: String, sandbox: TestSandbox, folder: URL, trashed: URL, kept: URL)
    {
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let kept = sandbox.root.appending(path: "home/.Trash/kept")
        let impostor = try sandbox.file("impostor", bytes: 9)
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let script = AdminScript.make([try putBackStep(trashed, into: folder)], planning: try sandbox.adminPlanning())
        // The first at_ ./helper is the destination check; the second is in the Trash.
        var hooks = on("at_", "./helper", nth: 2, "/bin/mv \(q(trashed)) \(q(kept)); /bin/cp \(q(impostor)) \(q(trashed))")
        if takeAgain {
            hooks += onBridgeRead("helper", flag: sandbox.root.appending(path: "flag"),
                                  "/usr/bin/printf again > \(q(trashed))")
        }
        return (output(of: hooked(script, hooks)), sandbox, folder, trashed, kept)
    }

    @Test func swappedSourceGoesBackToTheTrash() throws {
        let swap = try putBackWithSwap(takeAgain: false)
        #expect(swap.output == "R\t0\terr\n")
        #expect(contents(swap.folder).isEmpty)
        #expect(size(swap.trashed) == 9)
        #expect(size(swap.kept) == 4)
        #expect(contents(swap.sandbox.bridges).isEmpty)
    }

    @Test func swappedSourceThatCantGoBackStaysInTheBridge() throws {
        // The name in the Trash was taken again, so the impostor can't go back: it stays in the
        // bridge, unpublished; the step is err and the bridge is left (never rm -rf'ed).
        let swap = try putBackWithSwap(takeAgain: true)
        #expect(swap.output == "R\t0\terr\n")
        #expect(contents(swap.folder).isEmpty)
        #expect(size(swap.trashed) == 5)
        #expect(size(swap.kept) == 4)
        let bridges = contents(swap.sandbox.bridges)
        #expect(bridges.count == 1)
        #expect(size(swap.sandbox.bridges.appending(path: "\(bridges.first ?? "")/0/helper")) == 9)
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
        #expect(AdminScript.parse(output, count: 6) == [
            .done,
            .notDone(reason: "already gone"),
            .notDone(reason: "kept because the app itself was not removed"),
            .notDone(reason: "something with the same name is already there"),
            .notDone(reason: "macOS refused, even with your password"),
            .notDone(reason: "Dustling can't safely move this with your password. Move it to the Trash in Finder."),
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
