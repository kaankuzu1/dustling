import Foundation
import Testing
@testable import DustlingCore

/// The scripts run for real, but only as the current user through `UserShell` (`/bin/sh -c`) and
/// only on paths inside a `TestSandbox`. `OsascriptAdminShell` is never built with privileges here:
/// that would put a password box on the screen. A test can't make root-owned folders, so planning
/// is told which sandbox folders count as root-only chains (`TestSandbox.rootOnlyOutsideHome`:
/// everything outside `home`, like `/Library`; the Trash in `home` is not).
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

    private func contents(_ url: URL) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? [])
    }

    private func run(_ steps: [AdminStep], in sandbox: TestSandbox) -> [AdminStepResult] {
        let script = AdminScript.make(steps, rootOnly: sandbox.rootOnlyOutsideHome)
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
        ], in: sandbox)
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
        let results = run([move(missing, trash.appending(path: "missing"))], in: sandbox)
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
        let results = run([move(source, taken), move(linkSource, danglingLink)], in: sandbox)
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
        let results = run([
            move(a, trash.appending(path: "a"), dependsOn: 1),
            move(b, trash.appending(path: "b"), dependsOn: 7),
        ], in: sandbox)
        let skipped = AdminStepResult.notDone(reason: "kept because the app itself was not removed")
        #expect(results == [skipped, skipped])
        #expect(exists(a))
        #expect(exists(b))
    }

    /// Script text only (never run): what planning found is made up. Destination (or item)
    /// folders are 7:42:501, source folders 7:41:0, unless `sourceDevice` says otherwise. By default
    /// the source chain is root-only and the destination's isn't (a move to the Trash).
    private func text(
        _ steps: [AdminStep], destinationRootOnly: Bool = false, sourceRootOnly: Bool = true, sourceDevice: UInt64 = 7
    ) -> String {
        let folder = AdminScript.PlannedFolder(
            identity: ItemIdentity(device: 7, inode: 42, owner: 501), rootOnly: destinationRootOnly)
        let source = AdminScript.PlannedFolder(
            identity: ItemIdentity(device: sourceDevice, inode: 41, owner: 0), rootOnly: sourceRootOnly)
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
            "move_out_ 0 - 1 - 1 '/Library/LaunchDaemons' 7:41:0 'com.example.helper.plist' '/Users/u/.Trash' 7:42:501 'com.example.helper.plist'",
            "move_out_ 1 - 0 - 1 '/Library/Caches' 7:41:0 'com.example' '/Users/u/.Trash' 7:42:501 'com.example'",
            "exit 0",
        ])
        // launchctl appears once, in boot_, only behind the bootout flag and only for a regular file
        // that is not a link.
        #expect(script.components(separatedBy: "launchctl").count == 2)
        #expect(script.contains(#"if [ "$1" = 1 ] && [ -f "$2" ] && ! [ -L "$2" ]; then /bin/launchctl bootout system "$2" >/dev/null 2>&1; fi"#))
        // In both moves boot_ comes after the volume and expected-identity checks and the staging
        // folder, and before any mv.
        let out = try body(of: "move_out_")
        let bootOut = try offset(of: #"boot_ "$b_" "$sp_""#, in: out)
        #expect(try offset(of: #"dev_ "$was_""#, in: out) < bootOut)
        #expect(try offset(of: #"[ "$was_" != "$e_" ]"#, in: out) < bootOut)
        #expect(try offset(of: #"enter_ "$did_""#, in: out) < bootOut)
        #expect(try offset(of: "/bin/mv ", in: out) > bootOut)
        let into = try body(of: "move_in_")
        let bootIn = try offset(of: #"boot_ "$b_" "$sd_/$sn_""#, in: into)
        #expect(try offset(of: #"dev_ "$was_""#, in: into) < bootIn)
        #expect(try offset(of: #"[ "$was_" != "$e_" ]"#, in: into) < bootIn)
        #expect(try offset(of: #"/bin/chmod -N "$sf_""#, in: into) < bootIn)
        #expect(try offset(of: "/bin/mv ", in: into) > bootIn)
    }

    @Test func scriptStartsSafelyAndUsesAbsoluteTools() throws {
        let script = text([
            AdminStep(op: .move(from: URL(filePath: "/Library/Caches/a"), to: URL(filePath: "/Users/u/.Trash/a"),
                                bootOutDaemon: false), dependsOn: nil),
            AdminStep(op: .delete(URL(filePath: "/Users/u/.Trash/b")), dependsOn: 0,
                      expectedSource: ItemIdentity(device: 1, inode: 2, owner: 0)),
        ])
        #expect(script.hasPrefix("set +e\nPATH=/usr/bin:/bin:/usr/sbin:/sbin\nexport PATH\n"))
        #expect(callLines(script) == [
            "move_out_ 0 - 0 - 1 '/Library/Caches' 7:41:0 'a' '/Users/u/.Trash' 7:42:501 'a'",
            "delete_ 1 0 1:2:0 '/Users/u/.Trash' 7:42:501 'b'",
            "exit 0",
        ])
        #expect(script.contains("\nme_=501\ntok_=T0K3N\n"))
        // Out of a root-only folder: the source by its root-only path into the pinned staging
        // folder, renamed inside it, published to its parent (the pinned destination).
        let out = try body(of: "move_out_")
        #expect(out.contains(#"/bin/mv -n -h -- "$sp_" . >/dev/null 2>&1"#))
        #expect(out.contains(#"/bin/mv -n -h -- "./$sn_" "./$dn_" >/dev/null 2>&1"#))
        #expect(out.contains(#"/bin/mv -n -h -- "./$dn_" .. >/dev/null 2>&1"#))
        // The destination (the Trash) is named by its path exactly once: to pin it.
        #expect(out.components(separatedBy: #""$dd_"#).count == 2)
        #expect(out.contains(#"pin_ "$dd_" "$did_""#))
        // Into a root-only folder: the source as ./name in its pinned folder, the destination by its
        // root-only path.
        let into = try body(of: "move_in_")
        #expect(into.contains(#"/bin/mv -n -h -- "./$sn_" "$sf_/$sn_" >/dev/null 2>&1"#))
        #expect(into.contains(#"/bin/mv -n -h -- "$sf_/$sn_" "$sf_/$dn_" >/dev/null 2>&1"#))
        #expect(into.contains(#"/bin/mv -n -h -- "$sf_/$dn_" "$dd_" >/dev/null 2>&1"#))
        // The source folder is named by its path to pin it, to tell gone from swapped when that
        // fails, and for boot_ (planned only when its chain is root-only).
        #expect(into.components(separatedBy: #""$sd_"#).count == 4)
        #expect(into.contains(#"pin_ "$sd_" "$sid_""#))
        #expect(into.contains(#"if at_ "$sd_"; then"#))
        // Never a path through the staging entry of a folder the user can write.
        #expect(!script.contains(#"./$st_/"#))
        #expect(script.contains(#"/bin/mkdir -m 700 -- "./$st_""#))
        #expect(script.contains("/bin/chmod -N . 2>/dev/null"))
        #expect(script.contains(#"/bin/rm -rfx -- "./$6" >/dev/null 2>&1"#))
        #expect(script.contains(#"[ "${is_%%:*}" != "${5%%:*}" ]"#))
        #expect(script.contains(#"cd -P -- "$1""#))
        #expect(!script.contains("chown"))
        // In the functions, every expansion sits inside double quotes.
        #expect(unquotedExpansions(in: #"rm -rf $1 "$2" '$3' "$(id_ "$4") $5""#) == 1)
        for line in AdminScript.prelude.split(separator: "\n") {
            #expect(unquotedExpansions(in: String(line)) == 0, "\(line)")
        }
        #expect(!script.contains("eval"))
        #expect(script.hasSuffix("exit 0\n"))
    }

    @Test func planningRefusesUnsafeMoves() {
        let trashed = URL(filePath: "/Users/u/.Trash/x")
        let recorded = ItemIdentity(device: 7, inode: 99, owner: 0)
        let putBack = AdminStep(op: .move(from: trashed, to: URL(filePath: "/Library/x"), bootOutDaemon: false),
                                expectedSource: recorded)
        let unchecked = AdminStep(op: .move(from: trashed, to: URL(filePath: "/Library/x"), bootOutDaemon: false))
        let numbered = AdminStep(op: .move(from: URL(filePath: "/Library/x"), to: URL(filePath: "/Users/u/.Trash/x 2"),
                                           bootOutDaemon: false))
        let daemon = AdminStep(op: .move(from: URL(filePath: "/Library/LaunchDaemons/d.plist"),
                                         to: URL(filePath: "/Users/u/.Trash/d.plist"), bootOutDaemon: true))
        // Into a root-only folder from one the user can write: only with the recorded identity.
        #expect(callLines(text([putBack], destinationRootOnly: true, sourceRootOnly: false)).first
            == "move_in_ 0 - 0 7:99:0 1 '/Users/u/.Trash' 7:41:0 'x' '/Library' 7:42:501 'x'")
        #expect(callLines(text([unchecked], destinationRootOnly: true, sourceRootOnly: false)).first
            == "report_ 0 err")
        // Between two root-only folders nothing can be swapped: no identity needed.
        #expect(callLines(text([unchecked], destinationRootOnly: true, sourceRootOnly: true)).first?
            .hasPrefix("move_in_ 0 - 0 - 1 ") == true)
        // Out of a root-only folder into one the user can write, also to a numbered name.
        #expect(callLines(text([numbered])).first
            == "move_out_ 0 - 0 - 0 '/Library' 7:41:0 'x' '/Users/u/.Trash' 7:42:501 'x 2'")
        // Never across volumes (mv would copy and delete instead of renaming).
        #expect(callLines(text([numbered], sourceDevice: 8)).first == "report_ 0 err")
        // Neither side root-only: refused with the Finder advice.
        #expect(callLines(text([numbered], sourceRootOnly: false)).first == "report_ 0 unsafe")
        #expect(callLines(text([putBack], destinationRootOnly: false, sourceRootOnly: false)).first
            == "report_ 0 unsafe")
        // Booting out a daemon whose plist folder chain isn't root-only: refused, whatever the other side.
        #expect(callLines(text([daemon], sourceRootOnly: false)).first == "report_ 0 unsafe")
        #expect(callLines(text([daemon], destinationRootOnly: true, sourceRootOnly: false)).first
            == "report_ 0 unsafe")
        #expect(callLines(text([daemon])).first?.hasPrefix("move_out_ 0 - 1 - 1 ") == true)
    }

    @Test func quoteEscapesEveryApostropheScalar() {
        let quoted = AdminScript.quote("a'\u{301}b'\u{FE0F}")
        #expect(Array(quoted.unicodeScalars) == Array("'a'\\''\u{301}b'\\''\u{FE0F}'".unicodeScalars))
    }

    // MARK: - The Trash side, raced (the reviewer's PoCs, made deterministic)

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

    private func q(_ url: URL) -> String {
        AdminScript.quote(url.path(percentEncoded: false))
    }

    /// `script` with `hooks` (sh functions replacing the prelude's) put right after the functions:
    /// what a program running as the user could do at that point.
    private func hooked(_ script: String, _ hooks: [String]) -> String {
        script.replacingOccurrences(of: "\nme_=", with: "\n" + hooks.joined(separator: "\n") + "\nme_=")
    }

    /// A move of `sys/x.plist` (6 bytes; `sys` planned as a root-only folder) into the Trash, with
    /// staging token `TOK`; `priv` stands for a folder only root can write, holding a victim
    /// `x.plist` (7 bytes) when `victim` is set.
    private struct TrashMove {
        let sandbox: TestSandbox
        let source: URL
        let trash: URL
        let priv: URL
        let staging: URL
        let step: AdminStep

        init(victim: Bool) throws {
            sandbox = try TestSandbox()
            source = try sandbox.file("sys/x.plist", bytes: 6)
            trash = try sandbox.directory("home/.Trash")
            priv = try sandbox.directory("priv")
            if victim { try sandbox.file("priv/x.plist", bytes: 7) }
            staging = trash.appending(path: ".dustling-TOK-0")
            step = AdminStep(op: .move(from: source, to: trash.appending(path: "x.plist"), bootOutDaemon: false))
        }

        var script: String {
            AdminScript.make([step], plans: [AdminScript.plan(of: step, rootOnly: sandbox.rootOnlyOutsideHome)],
                             token: "TOK")
        }

        /// Every entry under the sandbox (relative path → size; -2 for a link), read with lstat and
        /// never through a link.
        func tree() -> [String: Int64] {
            var found: [String: Int64] = [:]
            func walk(_ relative: String) {
                let path = sandbox.root.path(percentEncoded: false) + (relative.isEmpty ? "" : "/" + relative)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                    let child = relative.isEmpty ? name : relative + "/" + name
                    var info = stat()
                    guard lstat(path + "/" + name, &info) == 0 else { continue }
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
    }

    /// `before` with `removed` taken out and `added` put in.
    private func changed(_ before: [String: Int64], removing removed: [String] = [], adding added: [String: Int64])
        -> [String: Int64]
    {
        var expected = before
        for path in removed { expected[path] = nil }
        expected.merge(added) { $1 }
        return expected
    }

    @Test func stagingSwappedForALinkBeforeRootEntersItIsRefused() throws {
        // r3review poc1: the empty root-made staging folder in the Trash is replaced by a link to
        // a root-only folder. Root now enters the staging folder with cd -P and checks it, so it
        // never acts through the link.
        let move = try TrashMove(victim: false)
        // The link's target looks like a staging folder: empty, mode 700, owned by the user running
        // the script. Only its identity and its parent tell it apart.
        #expect(chmod(move.priv.path(percentEncoded: false), 0o700) == 0)
        let before = move.tree()
        // The hook keeps pin_ exactly as it is and adds the swap in front.
        #expect(AdminScript.prelude.contains(#"pin_() { cd -P -- "$1" 2>/dev/null && [ "$(id_ .)" = "$2" ]; }"#))
        let script = hooked(move.script, [
            "pin_() {",
            "  if [ \"$1\" = ./.dustling-TOK-0 ]; then",
            "    /bin/rmdir \(q(move.staging)) && /bin/ln -s \(q(move.priv)) \(q(move.staging))",
            "  fi",
            "  cd -P -- \"$1\" 2>/dev/null && [ \"$(id_ .)\" = \"$2\" ]",
            "}",
        ])
        #expect(output(of: script) == "R\t0\terr\n")
        #expect((try? fm.destinationOfSymbolicLink(atPath: move.staging.path(percentEncoded: false))) != nil)
        // Nothing changed but the link the other program made.
        #expect(move.tree() == changed(before, adding: ["home/.Trash/.dustling-TOK-0": -2]))
        #expect(contents(move.priv).isEmpty)
        #expect(size(move.source) == 6)
        #expect(contents(move.trash) == [".dustling-TOK-0"])
    }

    @Test func stagingSwappedForALinkAfterRootEnteredItIsNeverUsed() throws {
        // The same swap once root is inside the staging folder (just before the rename): the item
        // goes into the folder root is in and out to its parent, the Trash. The staging folder can't
        // be found again under its name, so the step reports err; nothing reaches the link's target.
        let move = try TrashMove(victim: false)
        let renamed = move.trash.appending(path: ".renamed")
        let before = move.tree()
        let script = hooked(move.script, [
            "boot_() { /bin/mv \(q(move.staging)) \(q(renamed)) && /bin/ln -s \(q(move.priv)) \(q(move.staging)); }",
        ])
        #expect(output(of: script) == "R\t0\terr\n")
        #expect(contents(move.priv).isEmpty)
        #expect(!exists(move.source))
        #expect(size(move.trash.appending(path: "x.plist")) == 6)
        #expect(contents(move.trash) == ["x.plist", ".dustling-TOK-0", ".renamed"])
        #expect(contents(renamed).isEmpty)
        // Only the chosen item moved, to its own Trash path; the rest is what the other program did.
        #expect(move.tree() == changed(before, removing: ["sys/x.plist"], adding: [
            "home/.Trash/x.plist": 6, "home/.Trash/.dustling-TOK-0": -2, "home/.Trash/.renamed": -1,
        ]))
    }

    @Test func stagingRenamedAfterTheItemWasVerifiedIsNeverUsed() throws {
        // r3review poc3: after root verified the staged item, the staging folder is renamed and a
        // link to a folder holding a same-named file put under its name. Root publishes from the
        // folder it is in (`mv ./x.plist ..`), so the victim is never taken; the step reports err.
        let move = try TrashMove(victim: true)
        let renamed = move.trash.appending(path: ".renamed")
        let before = move.tree()
        let script = hooked(move.script, [
            "id_() {",
            "  /usr/bin/stat -f '%d:%i:%u' -- \"$1\" 2>/dev/null",
            "  if [ \"$1\" = ./x.plist ]; then",
            "    /bin/mv \(q(move.staging)) \(q(renamed)) && /bin/ln -s \(q(move.priv)) \(q(move.staging))",
            "  fi",
            "}",
        ])
        #expect(output(of: script) == "R\t0\terr\n")
        #expect(contents(move.priv) == ["x.plist"])
        #expect(size(move.priv.appending(path: "x.plist")) == 7)
        #expect(!exists(move.source))
        #expect(size(move.trash.appending(path: "x.plist")) == 6)
        #expect(contents(move.trash) == ["x.plist", ".dustling-TOK-0", ".renamed"])
        #expect(contents(renamed).isEmpty)
        // Only the chosen item moved, to its own Trash path; the rest is what the other program did.
        #expect(move.tree() == changed(before, removing: ["sys/x.plist"], adding: [
            "home/.Trash/x.plist": 6, "home/.Trash/.dustling-TOK-0": -2, "home/.Trash/.renamed": -1,
        ]))
    }

    @Test func publishingBlockedPutsTheItemBack() throws {
        // Something takes the item's name in the Trash after root checked it was free: mv -n
        // doesn't publish, and the item goes back to its root-only folder.
        let move = try TrashMove(victim: false)
        let before = move.tree()
        let script = hooked(move.script, [
            "boot_() { /usr/bin/printf blocked > \(q(move.trash.appending(path: "x.plist"))); }",
        ])
        #expect(output(of: script) == "R\t0\terr\n")
        #expect(size(move.source) == 6)
        #expect(size(move.trash.appending(path: "x.plist")) == 7)
        #expect(move.tree() == changed(before, adding: ["home/.Trash/x.plist": 7]))
        #expect(hidden(in: move.trash).isEmpty)
    }

    @Test func failedMoveLeavesNoStagingFolder() throws {
        // The source vanishes just before the rename: nothing is staged, and the empty staging
        // folder is removed from the pinned Trash.
        let move = try TrashMove(victim: false)
        let script = hooked(move.script, ["boot_() { /bin/rm -f \(q(move.source)); }"])
        #expect(output(of: script) == "R\t0\terr\n")
        #expect(contents(move.trash).isEmpty)
        // The same for a Put back (the staging folder is in the destination).
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let step = AdminStep(op: .move(from: trashed, to: folder.appending(path: "helper"), bootOutDaemon: false),
                             expectedSource: try #require(ItemIdentity.of(trashed)))
        let putBack = hooked(AdminScript.make([step], rootOnly: sandbox.rootOnlyOutsideHome),
                             ["boot_() { /bin/rm -f \(q(trashed)); }"])
        #expect(putBack.contains("\nmove_in_ 0 "))
        #expect(output(of: putBack) == "R\t0\terr\n")
        #expect(contents(folder).isEmpty)
    }

    @Test func stagingFolderLosesInheritedPermissions() throws {
        // A user can put inheritable ACL entries on a folder they own, like the Trash; the folder
        // root makes there would get them. Root removes them before using it.
        let move = try TrashMove(victim: false)
        let user = String(cString: try #require(getpwuid(getuid())).pointee.pw_name)
        let rights = "\(user) allow list,add_file,search,add_subdirectory,delete_child,writesecurity,chown,"
            + "file_inherit,directory_inherit"
        let trashPath = move.trash.path(percentEncoded: false)
        #expect(try ProcessCommandRunner().run("/bin/chmod", ["+a", rights, trashPath]).status == 0)
        // Control: a folder made there inherits the entry.
        let control = try move.sandbox.directory("home/.Trash/control")
        let controlListing = try ProcessCommandRunner().run("/bin/ls", ["-led", control.path(percentEncoded: false)])
        #expect(controlListing.stdout.contains("inherited allow"))
        try fm.removeItem(at: control)
        let record = move.sandbox.root.appending(path: "staging.txt")
        let script = hooked(move.script, ["boot_() { /bin/ls -led . > \(q(record)); }"])
        #expect(output(of: script) == "R\t0\tok\n")
        let listing = try String(contentsOf: record, encoding: .utf8)
        #expect(listing.hasPrefix("drwx------"), "\(listing)")
        #expect(listing.split(separator: "\n").count == 1, "\(listing)")
        #expect(size(move.trash.appending(path: "x.plist")) == 6)
        #expect(hidden(in: move.trash).isEmpty)
    }

    // MARK: - Put back (into a root-only folder)

    private func putBackStep(_ trashed: URL, into folder: URL) throws -> AdminStep {
        AdminStep(op: .move(from: trashed, to: folder.appending(path: trashed.lastPathComponent), bootOutDaemon: false),
                  expectedSource: try #require(ItemIdentity.of(trashed)))
    }

    @Test func putBackIsStagedThenPublished() throws {
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/com.x.plist", bytes: 4)
        let folder = try sandbox.directory("Library/LaunchDaemons")
        let recorded = try #require(ItemIdentity.of(trashed))
        let script = AdminScript.make([try putBackStep(trashed, into: folder)], rootOnly: sandbox.rootOnlyOutsideHome)
        #expect(script.contains("\nmove_in_ 0 - 0 \(recorded.stamp) 1 '"))
        #expect(AdminScript.parse(output(of: script), count: 1) == [.done])
        #expect(ItemIdentity.of(folder.appending(path: "com.x.plist")) == recorded)
        #expect(!exists(trashed))
        #expect(hidden(in: folder).isEmpty)
    }

    /// Puts back `helper` from the Trash into a root-only folder; just before root's rename
    /// (`boot_`), another file is swapped in at `helper`. With `takeAgain`, the name is taken again
    /// right after root's rename. `me_` is set to `user`.
    private func putBackWithSwap(in sandbox: TestSandbox, user: uid_t, takeAgain: Bool) throws
        -> (output: String, folder: URL, trashed: URL, kept: URL)
    {
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let kept = sandbox.root.appending(path: "home/.Trash/kept")
        let impostor = try sandbox.file("impostor", bytes: 9)
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let step = try putBackStep(trashed, into: folder)
        let plan = AdminScript.plan(of: step, rootOnly: sandbox.rootOnlyOutsideHome)
        var hooks = ["boot_() { /bin/mv \(q(trashed)) \(q(kept)); /bin/cp \(q(impostor)) \(q(trashed)); }"]
        if takeAgain {
            hooks += [
                "id_() {",
                "  /usr/bin/stat -f '%d:%i:%u' -- \"$1\" 2>/dev/null",
                "  case \"$1\" in */.dustling-*/helper) [ -e \(q(trashed)) ] || /usr/bin/printf again > \(q(trashed)) ;; esac",
                "}",
            ]
        }
        let script = hooked(AdminScript.make([step], plans: [plan], user: user), hooks)
        return (output(of: script), folder, trashed, kept)
    }

    @Test func swappedSourceGoesBackToTheTrash() throws {
        let sandbox = try TestSandbox()
        let swap = try putBackWithSwap(in: sandbox, user: getuid(), takeAgain: false)
        #expect(swap.output == "R\t0\terr\n")
        #expect(contents(swap.folder).isEmpty)
        #expect(size(swap.trashed) == 9)
        #expect(size(swap.kept) == 4)
    }

    @Test func swappedSourceIsNeverPublished() throws {
        // The name in the Trash is taken again, so the impostor can't go back. The user's own is
        // deleted; nothing is published and the staging folder is removed.
        let ownSandbox = try TestSandbox()
        let own = try putBackWithSwap(in: ownSandbox, user: getuid(), takeAgain: true)
        #expect(own.output == "R\t0\terr\n")
        #expect(contents(own.folder).isEmpty)
        #expect(size(own.trashed) == 5)
        #expect(size(own.kept) == 4)
        // Someone else's (as seen by `me_`): kept inside the hidden staging folder, never published,
        // never moved anywhere else.
        let otherSandbox = try TestSandbox()
        let other = try putBackWithSwap(in: otherSandbox, user: getuid() &+ 1, takeAgain: true)
        #expect(other.output == "R\t0\terr\n")
        let left = contents(other.folder)
        #expect(left.count == 1 && left.first?.hasPrefix(".dustling-") == true)
        #expect(size(other.folder.appending(path: "\(left.first ?? "")/helper")) == 9)
        #expect(!exists(other.folder.appending(path: "helper")))
        #expect(size(other.trashed) == 5)
        #expect(size(other.kept) == 4)
    }

    @Test func trashSwappedJustBeforeTheRenameIsNeverUsed() throws {
        // Right before root's rename, the Trash (the source folder) is swapped for a link to a
        // folder holding a same-named item. Root names the source relative to the Trash it pinned,
        // so it still takes the recorded item; the other item is never touched.
        let sandbox = try TestSandbox()
        let trashed = try sandbox.file("home/.Trash/helper", bytes: 4)
        let victim = try sandbox.file("elsewhere/helper", bytes: 6)
        let trash = sandbox.root.appending(path: "home/.Trash")
        let realTrash = sandbox.root.appending(path: "home/Trash-real")
        let elsewhere = sandbox.root.appending(path: "elsewhere")
        let folder = try sandbox.directory("Library/PrivilegedHelperTools")
        let recorded = try #require(ItemIdentity.of(trashed))
        let step = try putBackStep(trashed, into: folder)
        let script = hooked(AdminScript.make([step], rootOnly: sandbox.rootOnlyOutsideHome), [
            "boot_() { /bin/mv \(q(trash)) \(q(realTrash)) && /bin/ln -s \(q(elsewhere)) \(q(trash)); }",
        ])
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
        let script = AdminScript.make(
            [step], plans: [AdminScript.plan(of: step, rootOnly: sandbox.rootOnlyOutsideHome)], token: "T0K3N")
        #expect(AdminScript.parse(output(of: script), count: 1)
            == [.notDone(reason: "macOS refused, even with your password")])
        #expect(size(item) == 4)
        #expect(contents(elsewhere).isEmpty)
    }

    @Test func moveToANumberedNameWorks() throws {
        let sandbox = try TestSandbox()
        let trash = try sandbox.directory("home/.Trash")
        try sandbox.file("home/.Trash/a.log", bytes: 1)
        let item = try sandbox.file("Library/Logs/a.log", bytes: 3)
        let script = AdminScript.make([move(item, trash.appending(path: "a 2.log"))], rootOnly: sandbox.rootOnlyOutsideHome)
        #expect(script.contains("\nmove_out_ 0 - 0 - 0 '"))
        #expect(AdminScript.parse(output(of: script), count: 1) == [.done])
        #expect(size(trash.appending(path: "a 2.log")) == 3)
        #expect(size(trash.appending(path: "a.log")) == 1)
        #expect(hidden(in: trash).isEmpty)
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
        #expect(!RootOnlyChain.contains(folder.path(percentEncoded: false)))
        #expect(!RootOnlyChain.isRootOnly(folder.path(percentEncoded: false)))
        // The owner can always give themselves write permission again.
        #expect(chmod(folder.path(percentEncoded: false), 0o555) == 0)
        defer { _ = chmod(folder.path(percentEncoded: false), 0o755) }
        #expect(!RootOnlyChain.isRootOnly(folder.path(percentEncoded: false)))
        let file = try sandbox.file("Library/file")
        #expect(!RootOnlyChain.isRootOnly(file.path(percentEncoded: false)))
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
        let results = run([
            AdminStep(op: .delete(tree), dependsOn: nil),
            AdminStep(op: .delete(missing), dependsOn: nil),
        ], in: sandbox)
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
        let results = run([AdminStep(op: .delete(withSlash), dependsOn: nil)], in: sandbox)
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
        let results = run(steps, in: sandbox)
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
