import Foundation

/// One thing the root script does.
public enum AdminOp: Equatable, Sendable {
    /// Renames `from` to `to`, never overwriting. With `bootOutDaemon`, the system launch daemon whose
    /// plist is `from` is stopped first. Only planned when one side's folder chain is root-only (see
    /// `AdminScript`).
    case move(from: URL, to: URL, bootOutDaemon: Bool)
    /// Deletes the item and everything inside it, never following symlinks or crossing mount points.
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
/// with status `ok`, `gone`, `skip`, `exists`, `err` or `unsafe`.
///
/// The rule everything follows: as root, a path is only ever resolved by name through folders
/// whose whole chain, from `/` down, is root-only — folders Dustling's user can't add, rename or
/// remove entries in, nor change the permissions or owner of (`RootOnlyChain`, checked when the
/// script is made, as the user). Any other folder is only entered (`cd -P <path>`), and what that
/// lands in must be the very directory planning saw (`stat -f '%d:%i:%u' .`: volume, inode,
/// owner); from there the script only names `.`, `..` and single entries (`./name`).
///
/// - Quoting: each step is one call line. Paths and names are single-quoted with `'` → `'\''`, done
///   on unicode scalars (a `'` followed by a combining mark is one Swift Character, so
///   Character-based replacing would miss it). Inside the functions every value is used
///   double-quoted, so the shell never expands, splits or globs anything from a name. Tools have
///   absolute paths and get `--` (except `chmod -N`, which takes `--` for a file name; it only
///   gets `.` or an absolute path); nothing is evaluated; paths never appear in comments or output.
/// - Planning (when the script is made) reads each folder a step touches with lstat: it must be a
///   real directory (its identity is recorded) and its chain is checked. A move runs only if
///   both folders are on one volume (a rename never turns into a copy) and one side is root-only:
///   - Out of a root-only folder (an item going to the Trash): `move_out_`, below.
///   - Into a root-only folder (Put back): `move_in_`, below. Unless the source folder is
///     root-only too, the step must carry `expectedSource`, or it is refused (`err`).
///   - Neither (a root-owned item in `~/Library`, `/Library/Caches` (sticky but anyone can add to
///     it), or `/Applications` for an admin; a Put back into such a folder): refused as `unsafe`
///     ("Dustling can't safely move this with your password. Move it to the Trash in Finder.").
///     So is `bootOutDaemon` unless the plist's folder chain is root-only. Nothing is ever chowned.
/// - `move_out_`: the source folder must still be the planned one (by its root-only path) and the
///   item must be on its volume and, when given, be `expectedSource`. The destination folder is
///   pinned and `./<new name>` must not exist. Root makes `./.dustling-<token>-<index>` there with
///   `mkdir -m 700`, enters it with `cd -P` and requires it to be what `mkdir` made: not a link, a
///   real directory owned by root, on the same volume, whose `..` is the pinned destination; it
///   removes any ACL the folder inherited (`chmod -N .`; a user can put inheritable entries on a
///   folder they own) and then requires mode 700, owner root and no entries. From then on only
///   root can change what is inside it, and it can't be moved to another folder (that takes write
///   permission on the folder itself). A daemon is booted out only now (and only a regular file,
///   not a link). Then `mv -n -h -- <source folder>/<name> .`; the staged `./<name>` must have the
///   identity read before; it is renamed inside if needed and published with `mv -n -h --
///   ./<new name> ..`; `ok` only if `../<new name>` has that identity and the staging folder was
///   removed from the re-pinned destination. If publishing fails, the item goes back to its root-only
///   source path. A staged item that is not the one read (only root could cause that) stays
///   parked in the staging folder. If nothing was staged, the empty staging folder is removed.
/// - `move_in_`: the source folder is pinned and the item named `./<name>`; it must be on the
///   folder's volume and, when given, be `expectedSource`. The destination folder (by its
///   root-only path) must be the planned one and `<destination>/<new name>` must not exist. Root
///   makes the staging folder inside the destination (`mkdir -m 700`, `chmod -N`, then mode 700,
///   owner root, no entries), boots out a daemon if asked, then `mv -n -h -- ./<name>
///   <destination>/<staging>/<name>`. The staged item must be the one read (so `expectedSource`);
///   only then is it renamed inside the staging folder if needed and published with `mv -n -h --
///   <staging>/<new name> <destination>`. Anything else is never published: it is moved back into
///   the pinned source folder under its name; if that name was taken again it is deleted when
///   Dustling's user owns it (only they could have made it), or else left in the locked staging
///   folder.
/// - `delete_`: the folder is pinned; `./<name>`, when there, must be on the folder's volume (not a
///   mount point) and, when given, be `expectedSource`; then `rm -rfx -- ./<name>` (never follows
///   links, never crosses mount points); `ok` iff it is gone.
///
/// What this guarantees, against a program running as Dustling's user (even with Full Disk
/// Access) that renames, replaces or mounts things in any folder the user can write, at any
/// moment: root names a path through such a folder only to enter it with `cd -P` (then checked by
/// identity) or to read (`stat`, an existence test); every change it makes is to an entry of a
/// pinned folder, of the staging folder it is in, of that folder's `..`, or of a root-only folder
/// named by its path. Into a root-only folder root puts only the item read at the
/// source (on Put back, the recorded `expectedSource`); the only other things root puts into a
/// root-only folder are an item moving back to the root-only folder it came from and, on Put back,
/// a swapped-in item that is not the user's own and couldn't be moved back, which stays unpublished
/// in the hidden 700 staging folder. Out of a root-only folder root moves only the requested
/// entry. Such a program can make a step fail (`err`), or make the requested item end up in a
/// folder the user can write other than the one asked for (it can move the Trash, or rename the
/// published item away).
///
/// What it doesn't: between `delete_`'s identity check and `rm`, `./<name>` can be swapped for
/// something else, which is then deleted instead: something already in that folder, or something
/// on the same volume the user could move there (moving a folder out of another folder takes
/// write permission on it, so never a root-owned one); `rm` stays inside it. A staging folder the
/// program renamed is not found again: the step reports `err` and that (then empty) folder stays
/// where it was put. The chains are checked once, at planning.
/// - A path that is not absolute, is `/`, has a `.` or `..` component or a NUL byte (checked on
///   UTF-8 bytes), or whose folder is not a real directory, never reaches a tool: `err`.
public enum AdminScript {
    public static let goneReason = "already gone"
    public static let skippedReason = "kept because the app itself was not removed"
    public static let existsReason = "something with the same name is already there"
    public static let refusedReason = "macOS refused, even with your password"
    public static let unsafeReason = "Dustling can't safely move this with your password. Move it to the Trash in Finder."
    public static let noResultReason = "no result"

    /// Reads each step's folders now (planning time) and builds the script.
    public static func make(_ steps: [AdminStep]) -> String {
        make(steps, rootOnly: RootOnlyChain.contains)
    }

    /// `rootOnly` says whether a folder's whole chain is root-only. Tests choose it: they can't
    /// make root-owned folders.
    static func make(_ steps: [AdminStep], rootOnly: (String) -> Bool) -> String {
        make(steps, plans: steps.map { plan(of: $0, rootOnly: rootOnly) })
    }

    /// What planning learned about a folder a step acts in.
    struct PlannedFolder: Equatable {
        let identity: ItemIdentity
        /// Whether the folder's whole chain is root-only (`RootOnlyChain`), so root may name paths
        /// through it.
        let rootOnly: Bool

        init(identity: ItemIdentity, rootOnly: Bool) {
            self.identity = identity
            self.rootOnly = rootOnly
        }

        /// The folder at `path` if it is a real directory right now (lstat).
        init?(path: String, rootOnly: (String) -> Bool) {
            guard let identity = ItemIdentity.of(path: path, directoryOnly: true) else { return nil }
            self.init(identity: identity, rootOnly: rootOnly(path))
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

    static func plan(of step: AdminStep, rootOnly: (String) -> Bool = RootOnlyChain.contains) -> StepPlan? {
        switch step.op {
        case .move(let from, let to, _):
            guard let source = AdminPath(from), let destination = AdminPath(to),
                  let folder = PlannedFolder(path: destination.folder, rootOnly: rootOnly)
            else { return nil }
            if let sourceFolder = PlannedFolder(path: source.folder, rootOnly: rootOnly) {
                return StepPlan(folder: folder, source: sourceFolder)
            }
            var info = stat()
            let missing = lstat(source.folder, &info) != 0 && errno == ENOENT
            return missing ? StepPlan(folder: folder, source: nil, sourceGone: true) : nil
        case .delete(let url):
            guard let item = AdminPath(url), let folder = PlannedFolder(path: item.folder, rootOnly: rootOnly)
            else { return nil }
            return StepPlan(folder: folder, source: nil)
        }
    }

    /// `plans[i]` is what planning found for step i (nil: a folder is not a real directory).
    /// `user` is the account Dustling runs as: only its own items may be deleted when staged by
    /// mistake. `token` makes the staging folders' names unique to this script.
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
        case "unsafe": return .notDone(reason: unsafeReason)
        default: return nil
        }
    }

    /// The functions every step calls. Arguments:
    /// - `move_out_` / `move_in_ <index> <head|-> <bootout 0|1> <expected identity|-> <same name 0|1>
    ///   <source folder> <source folder identity> <source name> <destination folder>
    ///   <destination folder identity> <new name>`
    /// - `delete_ <index> <head|-> <expected identity|-> <folder> <folder identity> <name>`
    /// `me_` (Dustling's user) and `tok_` (the staging token) are set after the functions; `run_` is
    /// the user running the script (root, or the current user in tests), who owns what it makes.
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
        pin_() { cd -P -- "$1" 2>/dev/null && [ "$(id_ .)" = "$2" ]; }
        empty_() { l_=$(/bin/ls -A -- "$1" 2>/dev/null) && [ -z "$l_" ]; }
        dev_() { [ -n "$1" ] && [ "${1%%:*}" = "${2%%:*}" ] && [ "${2%%:*}" = "${3%%:*}" ]; }
        boot_() {
          if [ "$1" = 1 ] && [ -f "$2" ] && ! [ -L "$2" ]; then /bin/launchctl bootout system "$2" >/dev/null 2>&1; fi
        }
        gone_() { if after_ "$2"; then report_ "$1" gone; else report_ "$1" skip; fi; }
        args_() {
          i_="$1"; h_="$2"; b_="$3"; e_="$4"; same_="$5"; sd_="$6"; sid_="$7"; sn_="$8"
          dd_="$9"; did_="${10}"; dn_="${11}"; st_=".dustling-$tok_-$1"
        }
        enter_() {
          stid_=$(id_ "./$st_")
          if [ -z "$stid_" ] || [ -L "./$st_" ] || ! pin_ "./$st_" "$stid_"; then return 1; fi
          if [ "${stid_##*:}" != "$run_" ] || [ "${stid_%%:*}" != "${1%%:*}" ] || [ "$(id_ ..)" != "$1" ]; then
            return 1
          fi
          /bin/chmod -N . 2>/dev/null || return 1
          [ "$(/usr/bin/stat -f '%Lp:%u' .)" = "700:$run_" ] && empty_ .
        }
        leave_() {
          if [ "$(id_ .)" != "$1" ]; then pin_ .. "$1" || return 1; fi
          /bin/rmdir -- "./$st_" 2>/dev/null
        }
        move_out_() {
          args_ "$@"; sp_="$sd_/$sn_"
          if ! after_ "$h_"; then report_ "$i_" skip; return; fi
          if ! at_ "$sd_"; then report_ "$i_" gone; return; fi
          if [ "$(id_ "$sd_")" != "$sid_" ]; then report_ "$i_" err; return; fi
          if ! at_ "$sp_"; then report_ "$i_" gone; return; fi
          was_=$(id_ "$sp_")
          if ! dev_ "$was_" "$sid_" "$did_"; then report_ "$i_" err; return; fi
          if [ "$e_" != - ] && [ "$was_" != "$e_" ]; then report_ "$i_" err; return; fi
          if ! pin_ "$dd_" "$did_"; then report_ "$i_" err; return; fi
          if at_ "./$dn_"; then report_ "$i_" exists; return; fi
          if ! /bin/mkdir -m 700 -- "./$st_" 2>/dev/null; then report_ "$i_" err; return; fi
          if ! enter_ "$did_"; then leave_ "$did_"; report_ "$i_" err; return; fi
          boot_ "$b_" "$sp_"
          /bin/mv -n -h -- "$sp_" . >/dev/null 2>&1
          got_=$(id_ "./$sn_")
          if [ -z "$got_" ]; then leave_ "$did_"; report_ "$i_" err; return; fi
          if [ "$got_" != "$was_" ]; then report_ "$i_" err; return; fi
          if [ "$same_" != 1 ]; then /bin/mv -n -h -- "./$sn_" "./$dn_" >/dev/null 2>&1; fi
          /bin/mv -n -h -- "./$dn_" .. >/dev/null 2>&1
          if at_ "./$dn_"; then
            /bin/mv -n -h -- "./$dn_" "$sp_" >/dev/null 2>&1
            if ! at_ "./$dn_"; then leave_ "$did_"; fi
            report_ "$i_" err; return
          fi
          if [ "$(id_ "../$dn_")" = "$was_" ] && leave_ "$did_"; then report_ "$i_" ok; else report_ "$i_" err; fi
        }
        move_in_() {
          args_ "$@"; sf_="$dd_/$st_"
          if ! after_ "$h_"; then report_ "$i_" skip; return; fi
          if ! pin_ "$sd_" "$sid_"; then
            if at_ "$sd_"; then report_ "$i_" err; else report_ "$i_" gone; fi
            return
          fi
          if ! at_ "./$sn_"; then report_ "$i_" gone; return; fi
          was_=$(id_ "./$sn_")
          if ! dev_ "$was_" "$sid_" "$did_"; then report_ "$i_" err; return; fi
          if [ "$e_" != - ] && [ "$was_" != "$e_" ]; then report_ "$i_" err; return; fi
          if [ "$(id_ "$dd_")" != "$did_" ]; then report_ "$i_" err; return; fi
          if at_ "$dd_/$dn_"; then report_ "$i_" exists; return; fi
          if ! /bin/mkdir -m 700 -- "$sf_" 2>/dev/null; then report_ "$i_" err; return; fi
          if ! /bin/chmod -N "$sf_" 2>/dev/null || [ -L "$sf_" ] || ! [ -d "$sf_" ] \
            || [ "$(/usr/bin/stat -f '%Lp:%u' -- "$sf_")" != "700:$run_" ] || ! empty_ "$sf_"; then
            /bin/rmdir -- "$sf_" 2>/dev/null; report_ "$i_" err; return
          fi
          boot_ "$b_" "$sd_/$sn_"
          /bin/mv -n -h -- "./$sn_" "$sf_/$sn_" >/dev/null 2>&1
          got_=$(id_ "$sf_/$sn_")
          if [ -z "$got_" ]; then /bin/rmdir -- "$sf_" 2>/dev/null; report_ "$i_" err; return; fi
          if [ "$got_" != "$was_" ]; then
            /bin/mv -n -h -- "$sf_/$sn_" . >/dev/null 2>&1
            if at_ "$sf_/$sn_" && [ "${got_##*:}" = "$me_" ]; then /bin/rm -rfx -- "$sf_/$sn_" >/dev/null 2>&1; fi
            /bin/rmdir -- "$sf_" 2>/dev/null
            report_ "$i_" err; return
          fi
          if [ "$same_" != 1 ]; then /bin/mv -n -h -- "$sf_/$sn_" "$sf_/$dn_" >/dev/null 2>&1; fi
          /bin/mv -n -h -- "$sf_/$dn_" "$dd_" >/dev/null 2>&1
          if [ "$(id_ "$dd_/$dn_")" = "$was_" ] && ! at_ "$sf_/$dn_" && /bin/rmdir -- "$sf_" 2>/dev/null; then
            report_ "$i_" ok
          else
            report_ "$i_" err
          fi
        }
        delete_() {
          if ! after_ "$2"; then report_ "$1" skip; return; fi
          if ! pin_ "$4" "$5"; then report_ "$1" err; return; fi
          if at_ "./$6"; then
            is_=$(id_ "./$6")
            if [ "${is_%%:*}" != "${5%%:*}" ] || { [ "$3" != - ] && [ "$is_" != "$3" ]; }; then
              report_ "$1" err; return
            fi
          fi
          /bin/rm -rfx -- "./$6" >/dev/null 2>&1
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
        let unsafe = "report_ \(index) unsafe"
        let expected = step.expectedSource?.stamp ?? "-"
        guard let plan else { return refused }
        switch step.op {
        case .move(let from, let to, let bootOutDaemon):
            if plan.sourceGone { return "gone_ \(index) \(head)" }
            guard let source = AdminPath(from), let destination = AdminPath(to), let sourceFolder = plan.source
            else { return refused }
            // A rename across volumes would make mv copy and delete instead.
            guard sourceFolder.identity.device == plan.folder.identity.device else { return refused }
            // launchctl reads the plist by its path: only through a root-only chain.
            if bootOutDaemon && !sourceFolder.rootOnly { return unsafe }
            let function: String
            if plan.folder.rootOnly {
                // Into a root-only folder root only puts what it can prove came from Put back,
                // unless the source can't be swapped either.
                if !sourceFolder.rootOnly && step.expectedSource == nil { return refused }
                function = "move_in_"
            } else if sourceFolder.rootOnly {
                function = "move_out_"
            } else {
                return unsafe
            }
            let sameName = Array(source.name.utf8) == Array(destination.name.utf8)
            return [function, String(index), head, bootOutDaemon ? "1" : "0", expected, sameName ? "1" : "0",
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

/// Whether root may resolve a path through a folder: the folder and every folder above it, from
/// `/` down, is root-only from Dustling's user's point of view, so no program running as that user
/// can add, rename or remove entries in any of them, or change their permissions to do so.
///
/// A folder is root-only when it is a real directory (lstat; a symlink anywhere in the chain, like
/// `/tmp` or `/var`, fails), not owned by the user, not writable by others, not writable by a group
/// the user is in, and `access(2)` (the user's real view, ACLs included) denies adding files or
/// subfolders, removing entries, changing permissions and taking ownership, each with `EACCES` or
/// `EROFS`. Any other answer (such as `EPERM` from a sandbox or privacy protection, which could
/// hide what another program may do) counts as writable. A sticky folder anyone can add to, like
/// `/Library/Caches`, is not root-only.
enum RootOnlyChain {
    static func contains(_ folder: String) -> Bool {
        let bytes = Array(folder.utf8)
        guard bytes.first == UInt8(ascii: "/"), !bytes.contains(0) else { return false }
        var prefixes = ["/"]
        var path = ""
        for component in bytes.split(separator: UInt8(ascii: "/")) {
            path += "/" + String(decoding: component, as: UTF8.self)
            prefixes.append(path)
        }
        return prefixes.allSatisfy(isRootOnly)
    }

    /// The rights that would let the user change a folder's entries or its permissions.
    private static let rights: [Int32] = [W_OK, _WRITE_OK, _APPEND_OK, _RMFILE_OK, _WPERM_OK, _CHOWN_OK]

    static func isRootOnly(_ folder: String) -> Bool {
        var info = stat()
        guard lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard info.st_uid != getuid(), info.st_mode & S_IWOTH == 0 else { return false }
        if info.st_mode & S_IWGRP != 0 && userIsMember(of: info.st_gid) { return false }
        for right in rights {
            if access(folder, right) == 0 { return false }
            let code = errno
            guard code == EACCES || code == EROFS else { return false }
        }
        return true
    }

    /// Whether the user is in `group`; true when it can't be told.
    private static func userIsMember(of group: gid_t) -> Bool {
        if group == getgid() || group == getegid() { return true }
        guard let entry = getpwuid(getuid()), let name = entry.pointee.pw_name else { return true }
        var count: Int32 = 1024
        var groups = [Int32](repeating: 0, count: Int(count))
        guard getgrouplist(name, Int32(bitPattern: getgid()), &groups, &count) == 0 else { return true }
        return groups.prefix(Int(count)).contains(Int32(bitPattern: group))
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
