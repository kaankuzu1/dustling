import Foundation

/// One thing the root script does.
public enum AdminOp: Equatable, Sendable {
    /// Renames `from` to `to`, never overwriting. With `bootOutDaemon`, the system launch daemon whose
    /// plist is `from` is stopped first.
    case move(from: URL, to: URL, bootOutDaemon: Bool)
    /// Deletes the item and everything inside it, never following symlinks.
    case delete(URL)
}

public struct AdminStep: Equatable, Sendable {
    public let op: AdminOp
    /// Index of an earlier step in the same batch that must have succeeded for this one to run (an
    /// app's leftovers depend on the app). Anything other than an earlier index keeps the step from
    /// running.
    public let dependsOn: Int?
    /// When set, the item moved (the source) or deleted must still be exactly this one, or the step
    /// does nothing and reports `err`. Put back passes the identity the journal recorded.
    public let expectedSource: ItemIdentity?

    public init(op: AdminOp, dependsOn: Int? = nil, expectedSource: ItemIdentity? = nil) {
        self.op = op
        self.dependsOn = dependsOn
        self.expectedSource = expectedSource
    }
}

public enum AdminStepResult: Equatable, Sendable {
    case done
    case notDone(reason: String)
    /// The user closed the password box, so nothing ran.
    case cancelled
}

/// Builds the one POSIX sh script that does every step of a user action as root, and reads back
/// what happened. The script prints exactly one line per step, `R<TAB><index><TAB><status>`,
/// with status `ok`, `gone`, `skip`, `exists` or `err`.
///
/// Safety:
/// - Each step is one call line. Paths and names are single-quoted with `'` → `'\''`, done on
///   unicode scalars (a `'` followed by a combining mark is one Swift Character, so Character-based
///   replacing would miss it). Inside the functions every value is used double-quoted, so the shell
///   never expands, splits or globs anything from a name. Tools have absolute paths and get `--`;
///   nothing is evaluated; paths never appear in comments or output.
/// - When the script is made, each folder a step touches (a move's source and destination folders,
///   a delete's item folder) is read with lstat: its identity (device, inode, owner) and whether
///   Dustling's user can write it. At run time a step only ever acts inside a folder it has just
///   `cd -P`ed into and found to be that same directory; a folder swapped for a link or another
///   folder makes the step `err`. Items are only named relative to such a pinned folder (`./name`),
///   except for the one cross-folder rename of a move (below).
/// - A move is refused when planned (`err`, never run) if its folders are on different volumes, if
///   it goes into a folder the user can't write without `expectedSource` (Put back passes the
///   identity the journal recorded), or if it boots out a daemon whose plist folder the user can
///   write. When run:
///   1. In the pinned source folder it reads `./<name>`'s identity: it must be on that folder's
///      volume and, when given, be `expectedSource`.
///   2. In the pinned destination folder, `./<new name>` must not exist; root makes a hidden 0700
///      staging folder there (`.dustling-<token>-<index>`) and checks it is a real directory owned
///      by the user running the script (root) with mode 700.
///   3. A daemon is booted out (`launchctl bootout system <plist>`) only now, after those checks.
///   4. Back in the pinned source folder: `mv -n -h -- ./<name> <destination folder>/<staging>/<name>`.
///   5. In the re-pinned destination folder, the staging folder must still be the one made in 2 and
///      the staged item must have exactly the identity read in 1. Only then is it published: given
///      its new name inside the staging folder (which only root can enter) if it changes, then
///      moved out with `mv … .`, so mv never treats `./<new name>` as a folder to move into; the
///      staging folder is removed; `ok` only if `./<new name>` has that identity. Anything else is
///      never published and never moved back out: it is deleted when it is owned by Dustling's
///      user (only they could have put it there), otherwise left in the hidden staging folder; the
///      step is `err`.
///
///   What this guarantees: root removes or publishes only entries of pinned folders; a destination
///   folder receives, under the requested name, only the very item read in the source folder; mv's
///   copy-and-delete fallback (taken when a rename crosses volumes) can only delete the
///   `./<name>` entry of the pinned source folder. What it doesn't: the cross-folder rename in
///   step 4 names the destination folder by its path. When that path runs through folders the user
///   can write (the Trash), a program running as the user can redirect it at that instant to
///   another folder holding a same-named staging folder, which can only be one the user can write
///   (even on another volume, as a copy); the step then reports `err`. If the final rename fails
///   because `./<new name>` appeared in that instant, the verified item stays in the staging
///   folder and the step reports `err`.
/// - A path that is not absolute, is `/`, has a `.` or `..` component or a NUL byte (checked on
///   UTF-8 bytes), or whose folder is not a real directory, never reaches a tool: `err`.
public enum AdminScript {
    public static let goneReason = "already gone"
    public static let skippedReason = "kept because the app itself was not removed"
    public static let existsReason = "something with the same name is already there"
    public static let refusedReason = "macOS refused, even with your password"
    public static let noResultReason = "no result"

    /// Reads each step's folders now (planning time) and builds the script.
    public static func make(_ steps: [AdminStep]) -> String {
        make(steps, plans: steps.map(plan))
    }

    /// What planning learned about a folder a step acts in.
    struct PlannedFolder: Equatable {
        let identity: ItemIdentity
        /// Whether Dustling's user could change the folder (and so race root inside it).
        let userCanWrite: Bool

        init(identity: ItemIdentity, userCanWrite: Bool) {
            self.identity = identity
            self.userCanWrite = userCanWrite
        }

        /// The folder at `path` if it is a real directory right now (lstat).
        init?(path: String) {
            guard let identity = ItemIdentity.of(path: path, directoryOnly: true) else { return nil }
            self.init(identity: identity, userCanWrite: access(path, W_OK) == 0)
        }
    }

    /// The folders a step acts in: a move's destination and source folders, a delete's item folder.
    /// `source` is nil for a delete, or for a move whose source folder no longer exists
    /// (`sourceGone`: the item is already gone).
    struct StepPlan: Equatable {
        let folder: PlannedFolder
        let source: PlannedFolder?
        var sourceGone = false
    }

    static func plan(of step: AdminStep) -> StepPlan? {
        switch step.op {
        case .move(let from, let to, _):
            guard let source = AdminPath(from), let destination = AdminPath(to),
                  let folder = PlannedFolder(path: destination.folder)
            else { return nil }
            if let sourceFolder = PlannedFolder(path: source.folder) {
                return StepPlan(folder: folder, source: sourceFolder)
            }
            var info = stat()
            let missing = lstat(source.folder, &info) != 0 && errno == ENOENT
            return missing ? StepPlan(folder: folder, source: nil, sourceGone: true) : nil
        case .delete(let url):
            guard let item = AdminPath(url), let folder = PlannedFolder(path: item.folder) else { return nil }
            return StepPlan(folder: folder, source: nil)
        }
    }

    /// `plans[i]` is what planning found for step i (nil: a folder is not a real directory).
    /// `user` is the account Dustling runs as: only its own items may be deleted when staged by
    /// mistake. `token` makes the staging folders' names unpredictable.
    static func make(
        _ steps: [AdminStep], plans: [StepPlan?], user: uid_t = getuid(), token: String = newToken()
    ) -> String {
        var lines = [prelude, "me_=\(user)", "tok_=\(token)"]
        for (index, step) in steps.enumerated() {
            lines.append(call(for: step, at: index, plan: index < plans.count ? plans[index] : nil))
        }
        // A non-zero exit would make osascript throw away everything the script printed.
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }

    static func newToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
    }

    /// One result per step, in order. A step without a line (or with an unreadable one) is
    /// `.notDone(reason: "no result")`; when a step has several lines the first one counts.
    public static func parse(_ output: String, count: Int) -> [AdminStepResult] {
        guard count > 0 else { return [] }
        var results = [AdminStepResult?](repeating: nil, count: count)
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "R",
                  let index = Int(fields[1]), results.indices.contains(index), results[index] == nil,
                  let result = result(for: String(fields[2]))
            else { continue }
            results[index] = result
        }
        return results.map { $0 ?? .notDone(reason: noResultReason) }
    }

    private static func result(for status: String) -> AdminStepResult? {
        switch status {
        case "ok": return .done
        case "gone": return .notDone(reason: goneReason)
        case "skip": return .notDone(reason: skippedReason)
        case "exists": return .notDone(reason: existsReason)
        case "err": return .notDone(reason: refusedReason)
        default: return nil
        }
    }

    /// The functions every step calls. Arguments:
    /// - `move_ <index> <head|-> <bootout 0|1> <expected identity|-> <same name 0|1> <source folder>
    ///   <source folder identity> <source name> <destination folder> <destination folder identity>
    ///   <new name>`
    /// - `delete_ <index> <head|-> <expected identity|-> <folder> <folder identity> <name>`
    /// `me_` (Dustling's user) and `tok_` (the staging token) are set after the functions; `run_` is
    /// the user running the script (root, or the current user in tests).
    static let prelude = #"""
        set +e
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        unset CDPATH
        ok_=' '
        run_=$(/usr/bin/id -u)
        id_() { /usr/bin/stat -f '%d:%i:%u' -- "$1" 2>/dev/null; }
        at_() { [ -e "$1" ] || [ -L "$1" ]; }
        report_() {
          if [ "$2" = ok ]; then ok_="$ok_$1 "; fi
          printf 'R\t%s\t%s\n' "$1" "$2"
        }
        after_() {
          if [ "$1" = - ]; then return 0; fi
          case "$ok_" in *" $1 "*) return 0 ;; esac
          return 1
        }
        in_() { cd -P -- "$1" 2>/dev/null && [ "$(id_ .)" = "$2" ]; }
        unstage_() { if in_ "$dd_" "$did_"; then /bin/rmdir -- "./$st_" 2>/dev/null; fi; }
        gone_() { if after_ "$2"; then report_ "$1" gone; else report_ "$1" skip; fi; }
        move_() {
          i_="$1"; h_="$2"; b_="$3"; e_="$4"; same_="$5"; sd_="$6"; sid_="$7"; sn_="$8"
          dd_="$9"; did_="${10}"; dn_="${11}"; st_=".dustling-$tok_-$1"
          if ! after_ "$h_"; then report_ "$i_" skip; return; fi
          if ! in_ "$sd_" "$sid_"; then
            if at_ "$sd_"; then report_ "$i_" err; else report_ "$i_" gone; fi
            return
          fi
          if ! at_ "./$sn_"; then report_ "$i_" gone; return; fi
          was_=$(id_ "./$sn_")
          if [ -z "$was_" ] || [ "${was_%%:*}" != "${sid_%%:*}" ] || [ "${sid_%%:*}" != "${did_%%:*}" ]; then
            report_ "$i_" err; return
          fi
          if [ "$e_" != - ] && [ "$was_" != "$e_" ]; then report_ "$i_" err; return; fi
          if ! in_ "$dd_" "$did_"; then report_ "$i_" err; return; fi
          if at_ "./$dn_"; then report_ "$i_" exists; return; fi
          if ! /bin/mkdir -m 700 -- "./$st_" 2>/dev/null; then report_ "$i_" err; return; fi
          stid_=$(id_ "./$st_")
          if [ -L "./$st_" ] || ! [ -d "./$st_" ] || [ "${stid_##*:}" != "$run_" ] \
            || [ "$(/usr/bin/stat -f '%Lp' -- "./$st_")" != 700 ]; then
            report_ "$i_" err; return
          fi
          if [ "$b_" = 1 ]; then /bin/launchctl bootout system "$sd_/$sn_" >/dev/null 2>&1; fi
          if ! in_ "$sd_" "$sid_"; then unstage_; report_ "$i_" err; return; fi
          /bin/mv -n -h -- "./$sn_" "$dd_/$st_/$sn_" >/dev/null 2>&1
          if ! in_ "$dd_" "$did_" || [ "$(id_ "./$st_")" != "$stid_" ]; then report_ "$i_" err; return; fi
          got_=$(id_ "./$st_/$sn_")
          if [ "$got_" != "$was_" ]; then
            if [ -n "$got_" ] && [ "${got_##*:}" = "$me_" ]; then /bin/rm -rf -- "./$st_/$sn_" >/dev/null 2>&1; fi
            /bin/rmdir -- "./$st_" 2>/dev/null
            report_ "$i_" err; return
          fi
          if [ "$same_" != 1 ]; then /bin/mv -n -h -- "./$st_/$sn_" "./$st_/$dn_" >/dev/null 2>&1; fi
          /bin/mv -n -h -- "./$st_/$dn_" . >/dev/null 2>&1
          if [ "$(id_ "./$dn_")" = "$was_" ] && ! at_ "./$st_/$dn_"; then
            /bin/rmdir -- "./$st_" 2>/dev/null
            report_ "$i_" ok
          else
            report_ "$i_" err
          fi
        }
        delete_() {
          if ! after_ "$2"; then report_ "$1" skip; return; fi
          if ! in_ "$4" "$5"; then report_ "$1" err; return; fi
          if [ "$3" != - ] && at_ "./$6" && [ "$(id_ "./$6")" != "$3" ]; then report_ "$1" err; return; fi
          /bin/rm -rf -- "./$6" >/dev/null 2>&1
          if at_ "./$6"; then report_ "$1" err; else report_ "$1" ok; fi
        }
        """#

    /// The one line that runs this step.
    private static func call(for step: AdminStep, at index: Int, plan: StepPlan?) -> String {
        var head = "-"
        if let dependsOn = step.dependsOn {
            guard (0..<index).contains(dependsOn) else { return "report_ \(index) skip" }
            head = String(dependsOn)
        }
        let refused = "report_ \(index) err"
        let expected = step.expectedSource?.stamp ?? "-"
        guard let plan else { return refused }
        switch step.op {
        case .move(let from, let to, let bootOutDaemon):
            if plan.sourceGone { return "gone_ \(index) \(head)" }
            guard let source = AdminPath(from), let destination = AdminPath(to), let sourceFolder = plan.source
            else { return refused }
            // A rename across volumes would make mv copy and delete instead.
            guard sourceFolder.identity.device == plan.folder.identity.device else { return refused }
            // Root only puts into a folder the user can't write what it can prove came from Put back.
            if !plan.folder.userCanWrite && step.expectedSource == nil { return refused }
            // launchctl reads the plist by path: only where the user can't swap it.
            if bootOutDaemon && sourceFolder.userCanWrite { return refused }
            // A new name ("name 2") is given inside the staging folder first, which only root can
            // enter, so publishing is always `mv … .` and mv never treats `./<new name>` as a folder.
            let sameName = Array(source.name.utf8) == Array(destination.name.utf8)
            return ["move_", String(index), head, bootOutDaemon ? "1" : "0", expected, sameName ? "1" : "0",
                    quote(source.folder), sourceFolder.identity.stamp, quote(source.name),
                    quote(destination.folder), plan.folder.identity.stamp, quote(destination.name)]
                .joined(separator: " ")
        case .delete(let url):
            guard let item = AdminPath(url) else { return refused }
            return ["delete_", String(index), head, expected, quote(item.folder), plan.folder.identity.stamp,
                    quote(item.name)]
                .joined(separator: " ")
        }
    }

    /// Single-quotes `text` for sh. Works on unicode scalars so every U+0027 is escaped, even one
    /// that a following combining mark joins into a bigger Character.
    static func quote(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append("'")
        for scalar in text.unicodeScalars {
            if scalar == "'" {
                scalars.append(contentsOf: #"'\''"#.unicodeScalars)
            } else {
                scalars.append(scalar)
            }
        }
        scalars.append("'")
        return String(scalars)
    }
}

/// A path the root script may act on, split at its last slash. Checked on UTF-8 bytes, never on
/// Characters: a combining mark after `/` or `.` would hide a separator or a `..` from String APIs.
struct AdminPath: Equatable {
    /// Without trailing slashes, so a link is acted on itself, never followed to its target.
    let full: String
    let folder: String
    let name: String

    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")

    /// nil for anything that is not a file URL with an absolute path other than `/`, or that has a
    /// `.` or `..` component or a NUL byte.
    init?(_ url: URL) {
        guard url.isFileURL else { return nil }
        let bytes = Self.trimmed(Array(url.path(percentEncoded: false).utf8))
        guard bytes.first == Self.slash, bytes.count > 1, !bytes.contains(0) else { return nil }
        let parts = bytes.split(separator: Self.slash)
        guard !parts.contains(where: { $0.elementsEqual([Self.dot]) || $0.elementsEqual([Self.dot, Self.dot]) })
        else { return nil }
        guard let last = bytes.lastIndex(of: Self.slash) else { return nil }
        full = String(decoding: bytes, as: UTF8.self)
        folder = String(decoding: Self.trimmed(Array(bytes[...last])), as: UTF8.self)
        name = String(decoding: bytes[(last + 1)...], as: UTF8.self)
    }

    static func trimmingTrailingSlashes(_ path: String) -> String {
        String(decoding: trimmed(Array(path.utf8)), as: UTF8.self)
    }

    /// Drops trailing slashes, keeping a lone `/`.
    private static func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        while bytes.count > 1, bytes.last == slash { bytes.removeLast() }
        return bytes
    }
}
