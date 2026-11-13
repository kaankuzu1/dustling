import Foundation

/// One thing the root script does.
public enum AdminOp: Equatable, Sendable {
    /// Renames `from` to `to`, never overwriting. With `bootOutDaemon`, the system launch daemon whose
    /// plist is `from` is stopped first.
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

/// Where planning looks and what it trusts. The defaults are the real system; tests point the
/// bridge at a sandbox folder and the owner at themselves (they can't make root-owned folders).
struct AdminPlanning: Sendable {
    /// The folder each batch's bridge is made in. `/Library`: root-only, on the data volume.
    var bridgeParent = "/Library"
    /// The owner the bridge must have: root, who runs the script.
    var bridgeOwner: uid_t = 0
    /// Whether a folder's whole chain is root-only (`RootOnlyChain`). Required of the bridge's
    /// parent, and of the plist's folder for `bootOutDaemon` (launchctl reads the plist by path).
    var rootOnlyChain: @Sendable (String) -> Bool = { RootOnlyChain.contains($0) }
    /// Folders to count as ones Dustling's user can't write whatever the folder itself says (tests:
    /// a sandbox folder standing in for a system folder). Otherwise the opened folder is asked
    /// (`PlannedFolder.read`); a move into one the user can't write needs `expectedSource`.
    var locked: @Sendable (String) -> Bool = { _ in false }
    /// Whether a folder is a Trash: a move out of one is a Put back, refused with its own reason.
    var isTrash: @Sendable (String) -> Bool = AdminPlanning.trash(of: .current)

    /// `environment`'s Trash folders: `~/.Trash`, and `<volumes>/<volume>/.Trashes/<uid>`.
    static func trash(of environment: SystemEnvironment) -> @Sendable (String) -> Bool {
        let userTrash = AdminPath.trimmingTrailingSlashes(environment.userTrash.path(percentEncoded: false))
        let volumes = AdminPath.trimmingTrailingSlashes(environment.volumesDirectory.path(percentEncoded: false))
        let uid = String(environment.userID)
        return { folder in
            if folder == userTrash { return true }
            guard folder.hasPrefix(volumes + "/") else { return false }
            let parts = folder.dropFirst(volumes.count + 1).split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && !parts[0].isEmpty && parts[1] == ".Trashes" && parts[2] == uid
        }
    }
}

/// Builds the one POSIX sh script that does every step of a user action as root, and reads back
/// what happened. The script prints exactly one line per step, `R<TAB><index><TAB><status>`,
/// with status `ok`, `gone`, `skip`, `exists`, `err`, `unsafe`, `unsafe_putback`, `held` or
/// `held_other`. Before the first `held` step it prints the bridge's path once, `B<TAB><path>`.
///
/// Every step goes between a pinned folder and a root-only bridge on the same volume:
/// - The bridge: once per script, root makes `/Library/.dustling-XXXXXXXX` with `mktemp -d`
///   (`umask 077`), removes any inherited ACL (`chmod -N`) and requires a real directory, not a
///   link, owned by root, mode 700, empty, on the volume planning saw. Otherwise every step is
///   `err`. Planning requires `/Library`'s whole chain to be root-only. Each step gets its own
///   subfolder `<bridge>/<index>` (`mkdir -m 700`). At the end the bridge is removed if it is empty;
///   one that still holds something is left alone, never `rm -rf`ed.
/// - A folder is pinned: `cd -P <folder>`, then `stat -f '%d:%i:%u' .` must be the identity
///   planning saw (volume, inode, owner). From a pinned folder the script names only `.` and
///   `./<name>`.
/// - Every rename between folders is `rn_ <source> <folder>`: zsh's `zf_mv` builtin (`/bin/zsh -f`,
///   no startup files, the module from the sealed system volume), which is rename(2) and nothing
///   else. Across volumes it fails (EXDEV) and copies nothing; `/bin/mv` would copy with
///   `cp -PRp` and then `rm -rf` the source, so it is used only for renames inside a step's own
///   bridge folder. The target is always a folder operand (`.` of a pinned folder, or the step's
///   bridge folder), never a full path: `zf_mv` then renames onto `<folder>/<name>`, refuses a
///   directory there, and replaces a link or file there without following it.
/// - Out of a folder: pin it; right before the rename, `./<name>` must still have the identity
///   planning recorded for the item (`stat -f '%d:%i:%u'`, which doesn't follow a link; a disk image
///   mounted there is another volume), else nothing is done (`err`). Then
///   `rn_ ./<name> <bridge>/<index>`. In the bridge the item must have that identity again.
///   Anything else that got there stays there for good, unpublished and never given back:
///   `held_other`.
/// - Only the inode root took leaves the bridge: right before publishing or giving back, the item
///   in the bridge must have the item's planned identity, and the name must be free.
/// - Into a folder: inside the bridge the item gets its final name ("name 2"); the destination is
///   pinned and `rn_ <bridge>/<index>/<final> .`; `ok` only if `./<final>` then has the item's
///   identity. If it couldn't be published (the name was taken in the meantime, the destination
///   changed, or the rename failed) it is given back to the folder it came from (pinned again,
///   `rn_ <bridge>/<index>/<name> .`), and the step is `err`; if that doesn't happen either, it
///   stays in the bridge: `held` (the planned item, untouched).
/// - A move (to the Trash, or Put back) is out of the source folder and into the destination, with
///   the destination's name checked free first (`exists`). A delete (Empty Trash) is out of the
///   folder, then `rm -rfx` on the verified item inside the bridge (never following links, never
///   crossing mount points). `bootOutDaemon` stops the daemon (`launchctl bootout system <plist>`)
///   after the destination check and before the item is taken, and only if the plist is still the
///   planned item, a regular file and not a link.
///
/// Planning (when the script is made, as the user) opens each folder a step touches once
/// (`O_DIRECTORY | O_NOFOLLOW`, so a real directory) and reads through that descriptor its
/// identity, whether the user can write it and the item's identity in it (`PlannedFolder.read`).
/// It refuses a step when the item or a folder is on another volume than the bridge (or no bridge
/// can be made), a folder is not a real directory, `bootOutDaemon` is asked for a plist whose folder
/// chain isn't root-only, or a move goes into a folder the user can't write without
/// `expectedSource`: `unsafe_putback` ("Dustling can't safely put this back with your password. Use
/// Put Back in Finder.") for a move out of the Trash (`AdminPlanning.isTrash`), `unsafe` ("Dustling
/// can't safely move this with your password. Move it to the Trash in Finder.") for a move into the
/// Trash or a delete. A move whose item (or source folder) is missing reports `gone`; a delete whose
/// item is missing reports `ok` if it is still missing (and `err` if something appeared). An
/// `expectedSource` that isn't the item planning saw is `err`.
///
/// What this guarantees, against a program running as Dustling's user (even with Full Disk Access)
/// that renames, replaces or mounts things in any folder the user can write, at any moment:
/// - The only paths root names through folders are the bridge's (`/Library` is root-only and the
///   bridge is root's own 700 folder), the plist path for `launchctl bootout` (only through a
///   root-only chain), and the folders it pins, each followed by the identity check before
///   anything is done in it. Everything else is `.` or `./<name>` of a pinned folder. Paths are
///   also read (`stat`, existence tests), which changes nothing.
/// - Root never copies and never removes anything outside its bridge: every move is a rename, and
///   the only `rm` is of the verified item inside the bridge.
/// - Out of a folder root takes only `./<name>` of the very folder planning saw, and only after
///   checking it is still the planned item. Into a folder it puts only the very inode it took and
///   checked: the requested item at its destination, or given back to the folder it came from,
///   always as `<pinned folder>/<name>`, never through a link. It deletes only the planned item,
///   inside the bridge.
/// - Such a program can make a step fail (`err`, or `held`/`held_other` with what root took kept
///   in the bridge). It can make the requested item end up in a folder it can write other than the
///   one asked for (by moving the pinned destination folder, or renaming the item once published).
///
/// What it doesn't:
/// - The plan is what was there at planning time. An item swapped before planning is what gets
///   planned; Put back's `expectedSource` (from the journal) covers that.
/// - Between root's last check of `./<name>` and its rename, the entry can still change. If the
///   other entry is on the same volume, root takes it into the bridge, where it stays
///   (`held_other`); if it is a mount, the rename fails and nothing is taken (`err`).
/// - Between the check that the target name is free and the rename onto it, something can appear
///   there. A directory (a mount included) makes the rename fail. A link or a file is replaced by
///   the item (rename(2) replaces it; the link is never followed): in a folder the user can write
///   that is only something the other program could remove itself, and in a root-only folder only
///   root creates entries.
/// - Identities compare the item itself, not what is inside a folder item. A program holding an
///   open descriptor on a folder inside a user-owned item can still add or remove entries in it
///   while it sits in the bridge. It can only add something it could move there anyway (moving a
///   folder between folders takes write permission on that folder, so never a root-owned one), and
///   on Empty Trash that is then deleted with the item.
/// - A batch interrupted halfway (the Mac shuts down) leaves its hidden bridge in `/Library`. A held
///   item is never deleted: it stays in `<bridge>/<index>/`.
///
/// Quoting and input checks:
/// - Each step is one call line. Paths and names are single-quoted with `'` → `'\''`, done
///   on unicode scalars (a `'` followed by a combining mark is one Swift Character, so
///   Character-based replacing would miss it). Inside the functions every value is used
///   double-quoted, so the shell never expands, splits or globs anything from a name; `rn_` passes
///   its two values to zsh as arguments, never in its command text. Tools have absolute paths and
///   get `--` (except `chmod -N`, which takes `--` for a file name; it only gets an absolute path);
///   nothing is evaluated; no path appears in comments, and the only one in the output is the
///   bridge's own (`B` line).
/// - A path that is not absolute, is `/`, has a `.` or `..` component or a NUL byte (checked on
///   UTF-8 bytes) never reaches a tool: `err`.
public enum AdminScript {
    public static let goneReason = "already gone"
    public static let skippedReason = "kept because the app itself was not removed"
    public static let existsReason = "something with the same name is already there"
    public static let refusedReason = "macOS refused, even with your password"
    public static let unsafeReason = "Dustling can't safely move this with your password. Move it to the Trash in Finder."
    public static let putBackUnsafeReason = "Dustling can't safely put this back with your password. Use Put Back in Finder."
    /// `held_other`: what is left in the bridge is not the planned item (it changed between root's
    /// last check and the rename); where the item went, root can't tell.
    public static let movedAwayReason =
        "Something changed while it was moving, so Dustling stopped. Another program may have moved your item."
    public static let noResultReason = "no result"

    /// Reads each step's folders and item now (planning time) and builds the script.
    public static func make(_ steps: [AdminStep]) -> String {
        make(steps, planning: AdminPlanning())
    }

    static func make(_ steps: [AdminStep], planning: AdminPlanning) -> String {
        make(steps, plans: steps.map { plan(of: $0, planning: planning) }, bridge: PlannedBridge(planning),
             isTrash: planning.isTrash)
    }

    /// What planning learned about a folder a step acts in.
    struct PlannedFolder: Equatable {
        let identity: ItemIdentity
        /// Whether Dustling's user can write the folder.
        let userCanWrite: Bool
        /// Whether the folder's whole chain is root-only, so root may name a path through it.
        let rootOnlyChain: Bool

        init(identity: ItemIdentity, userCanWrite: Bool, rootOnlyChain: Bool) {
            self.identity = identity
            self.userCanWrite = userCanWrite
            self.rootOnlyChain = rootOnlyChain
        }

        enum Read: Equatable {
            /// A real directory, and the identity of the entry asked about (nil: nothing there).
            case found(PlannedFolder, item: ItemIdentity?)
            /// Nothing at the path (or above it).
            case missing
            /// A link, a file, or a folder that can't be opened.
            case unusable
        }

        /// The folder at `path`, read through one descriptor: `open(O_RDONLY | O_DIRECTORY |
        /// O_NOFOLLOW)`, then its identity (`fstat`), whether Dustling's user can write it
        /// (`faccessat(fd, ".", W_OK)`, the real ids as `access(2)` uses) and the identity of its
        /// entry `name` (`fstatat(fd, name, AT_SYMLINK_NOFOLLOW)`, lstat semantics). All of them
        /// belong to the same directory even if another program renames or replaces what is at
        /// `path` meanwhile. Only whether the folder's chain is root-only goes by `path`: no one but
        /// root can change such a chain. `afterOpen` runs right after the open (tests: a swap).
        static func read(_ path: String, item name: String?, planning: AdminPlanning, afterOpen: () -> Void = {})
            -> Read
        {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return errno == ENOENT ? .missing : .unusable }
            defer { close(fd) }
            afterOpen()
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return .unusable }
            let writable = !planning.locked(path) && faccessat(fd, ".", W_OK, 0) == 0
            var item: ItemIdentity?
            var entry = stat()
            if let name, fstatat(fd, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 { item = ItemIdentity(entry) }
            let folder = PlannedFolder(
                identity: ItemIdentity(info), userCanWrite: writable, rootOnlyChain: planning.rootOnlyChain(path))
            return .found(folder, item: item)
        }
    }

    /// Where the script makes its bridge, and what it must find there.
    struct PlannedBridge: Equatable {
        let parent: String
        let device: UInt64
        let owner: uid_t

        init(parent: String, device: UInt64, owner: uid_t) {
            self.parent = parent
            self.device = device
            self.owner = owner
        }

        /// nil when the parent is not a real directory with a root-only chain.
        init?(_ planning: AdminPlanning) {
            guard let parent = ItemIdentity.of(path: planning.bridgeParent, directoryOnly: true),
                  planning.rootOnlyChain(planning.bridgeParent)
            else { return nil }
            self.init(parent: planning.bridgeParent, device: parent.device, owner: planning.bridgeOwner)
        }
    }

    /// What planning learned for a step: a move's destination (`folder`) and source folders, or a
    /// delete's item folder (`folder`); and the item itself (nil: nothing there). `source` is nil
    /// for a delete, or for a move whose source folder no longer exists (`sourceGone`).
    struct StepPlan: Equatable {
        let folder: PlannedFolder
        let source: PlannedFolder?
        let item: ItemIdentity?
        var sourceGone = false
    }

    static func plan(of step: AdminStep, planning: AdminPlanning) -> StepPlan? {
        switch step.op {
        case .move(let from, let to, _):
            guard let source = AdminPath(from), let destination = AdminPath(to),
                  case .found(let folder, _) = PlannedFolder.read(destination.folder, item: nil, planning: planning)
            else { return nil }
            switch PlannedFolder.read(source.folder, item: source.name, planning: planning) {
            case .found(let sourceFolder, let item): return StepPlan(folder: folder, source: sourceFolder, item: item)
            case .missing: return StepPlan(folder: folder, source: nil, item: nil, sourceGone: true)
            case .unusable: return nil
            }
        case .delete(let url):
            guard let item = AdminPath(url),
                  case .found(let folder, let identity) = PlannedFolder.read(item.folder, item: item.name, planning: planning)
            else { return nil }
            return StepPlan(folder: folder, source: nil, item: identity)
        }
    }

    /// `plans[i]` is what planning found for step i (nil: a folder is not a real directory);
    /// `bridge` where the bridge goes (nil: it can't be made); `isTrash` which folders are a Trash
    /// (a refused move out of one is a Put back).
    static func make(
        _ steps: [AdminStep], plans: [StepPlan?], bridge: PlannedBridge?, isTrash: (String) -> Bool = { _ in false }
    ) -> String {
        let calls = steps.enumerated().map { index, step in
            call(for: step, at: index, plan: index < plans.count ? plans[index] : nil, bridge: bridge,
                 isTrash: isTrash)
        }
        var lines = [prelude, "own_=\(bridge?.owner ?? 0)"]
        let needsBridge = calls.contains { $0.hasPrefix("move_ ") || $0.hasPrefix("delete_ ") }
        if needsBridge, let bridge {
            lines.append("bridge_ \(quote(bridge.parent)) \(bridge.device)")
        }
        lines += calls
        if needsBridge { lines.append("end_") }
        // A non-zero exit would make osascript throw away everything the script printed.
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One result per step, in order. A step without a line (or with an unreadable one) is
    /// `.notDone(reason: "no result")`; when a step has several lines the first one counts. A
    /// `held` step's reason names the bridge from the script's `B<TAB><path>` line (the first one).
    public static func parse(_ output: String, count: Int) -> [AdminStepResult] {
        guard count > 0 else { return [] }
        let lines = output.split(whereSeparator: \.isNewline)
        let bridge = lines.lazy.compactMap { line -> String? in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return fields.count == 2 && fields[0] == "B" && !fields[1].isEmpty ? String(fields[1]) : nil
        }.first
        var results = [AdminStepResult?](repeating: nil, count: count)
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "R",
                  let index = Int(fields[1]), results.indices.contains(index), results[index] == nil,
                  let result = result(for: String(fields[2]), bridge: bridge)
            else { continue }
            results[index] = result
        }
        return results.map { $0 ?? .notDone(reason: noResultReason) }
    }

    /// Why a step is `held`: the planned item itself is still in the bridge at `bridge` (its path,
    /// from the script; nil if it didn't say), in that step's subfolder.
    public static func heldReason(bridge: String?) -> String {
        "Something changed while it was moving, so Dustling stopped. It is untouched in \(bridge ?? "a hidden folder in /Library")."
    }

    private static func result(for status: String, bridge: String?) -> AdminStepResult? {
        switch status {
        case "ok": return .done
        case "gone": return .notDone(reason: goneReason)
        case "skip": return .notDone(reason: skippedReason)
        case "exists": return .notDone(reason: existsReason)
        case "err": return .notDone(reason: refusedReason)
        case "unsafe": return .notDone(reason: unsafeReason)
        case "unsafe_putback": return .notDone(reason: putBackUnsafeReason)
        case "held": return .notDone(reason: heldReason(bridge: bridge))
        case "held_other": return .notDone(reason: movedAwayReason)
        default: return nil
        }
    }

    /// The functions every step calls. Arguments:
    /// - `bridge_ <parent> <device>` (once), `end_` (once, last)
    /// - `move_ <index> <head|-> <bootout 0|1> <expected identity|-> <same name 0|1> <source folder>
    ///   <source folder identity> <name> <item identity> <destination folder>
    ///   <destination folder identity> <new name>`
    /// - `delete_ <index> <head|-> <expected identity|-> <folder> <folder identity> <name>
    ///   <item identity|- when missing>`
    /// `own_`, the owner the bridge must have, is set after the functions. `take_` leaves `t_` as
    /// `ok` (the planned item is in `<bridge>/<index>`), `gone`, `err` (nothing taken) or
    /// `held_other` (something else got into the bridge and stays there). `rn_ <source> <folder>` is
    /// the only rename between folders (see above).
    static let prelude = #"""
        set +e
        umask 077
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        unset CDPATH
        ok_=' '
        br_=
        bok_=0
        bp_=0
        id_() { /usr/bin/stat -f '%d:%i:%u' -- "$1" 2>/dev/null; }
        at_() { [ -e "$1" ] || [ -L "$1" ]; }
        report_() {
          if [ "$2" = ok ]; then ok_="$ok_$1 "; fi
          if [ "$2" = held ] && [ "$bp_" != 1 ]; then printf 'B\t%s\n' "$br_"; bp_=1; fi
          printf 'R\t%s\t%s\n' "$1" "$2"
        }
        after_() {
          if [ "$1" = - ]; then return 0; fi
          case "$ok_" in *" $1 "*) return 0 ;; esac
          return 1
        }
        pin_() { cd -P -- "$1" 2>/dev/null && [ "$(id_ .)" = "$2" ]; }
        empty_() { l_=$(/bin/ls -A -- "$1" 2>/dev/null) && [ -z "$l_" ]; }
        gone_() { if after_ "$2"; then report_ "$1" gone; else report_ "$1" skip; fi; }
        bridge_() {
          br_=$(/usr/bin/mktemp -d "$1/.dustling-XXXXXXXX" 2>/dev/null) || br_=
          if [ -n "$br_" ] && ! [ -L "$br_" ] && [ -d "$br_" ] && /bin/chmod -N "$br_" 2>/dev/null \
            && [ "$(/usr/bin/stat -f '%d:%u:%Lp' -- "$br_")" = "$2:$own_:700" ] && empty_ "$br_"; then
            bok_=1
          fi
        }
        end_() { if [ -n "$br_" ]; then /bin/rmdir -- "$br_" 2>/dev/null; fi; }
        fin_() {
          if [ "$bok_" = 1 ]; then /bin/rmdir -- "$k_" 2>/dev/null; fi
          report_ "$i_" "$1"
        }
        rn_() { /bin/zsh -f -c 'zmodload -F zsh/files b:zf_mv && zf_mv -- "$1" "$2"' rn_ "$1" "$2" </dev/null >/dev/null 2>&1; }
        back_() { if pin_ "$1" "$2" && [ "$(id_ "$k_/$3")" = "$4" ] && ! at_ "./$3"; then rn_ "$k_/$3" .; fi; }
        take_() {
          t_=err
          if ! pin_ "$1" "$2"; then
            if ! at_ "$1"; then t_=gone; fi
            return
          fi
          if ! at_ "./$3"; then t_=gone; return; fi
          if [ "$5" != - ] && [ "$5" != "$4" ]; then return; fi
          /bin/mkdir -m 700 -- "$k_" 2>/dev/null || return
          if [ "$(id_ "./$3")" = "$4" ]; then rn_ "./$3" "$k_"; fi
          if [ "$(id_ "$k_/$3")" = "$4" ]; then t_=ok; elif ! empty_ "$k_"; then t_=held_other; fi
        }
        boot_() {
          if [ "$b_" = 1 ] && pin_ "$sd_" "$sid_" && [ "$(id_ "./$sn_")" = "$iid_" ] \
            && [ -f "./$sn_" ] && ! [ -L "./$sn_" ]; then
            /bin/launchctl bootout system "$sd_/$sn_" >/dev/null 2>&1
          fi
        }
        move_() {
          i_="$1"; h_="$2"; b_="$3"; e_="$4"; same_="$5"; sd_="$6"; sid_="$7"; sn_="$8"; iid_="$9"
          dd_="${10}"; did_="${11}"; dn_="${12}"; k_="$br_/$1"
          if ! after_ "$h_"; then report_ "$i_" skip; return; fi
          if [ "$bok_" != 1 ]; then report_ "$i_" err; return; fi
          if ! pin_ "$dd_" "$did_"; then report_ "$i_" err; return; fi
          if at_ "./$dn_"; then report_ "$i_" exists; return; fi
          boot_
          take_ "$sd_" "$sid_" "$sn_" "$iid_" "$e_"
          if [ "$t_" != ok ]; then fin_ "$t_"; return; fi
          if [ "$same_" != 1 ]; then /bin/mv -n -h -- "$k_/$sn_" "$k_/$dn_" >/dev/null 2>&1; fi
          if pin_ "$dd_" "$did_" && [ "$(id_ "$k_/$dn_")" = "$iid_" ] && ! at_ "./$dn_"; then rn_ "$k_/$dn_" .; fi
          if at_ "$k_/$dn_" || at_ "$k_/$sn_"; then
            if [ "$same_" != 1 ]; then /bin/mv -n -h -- "$k_/$dn_" "$k_/$sn_" >/dev/null 2>&1; fi
            back_ "$sd_" "$sid_" "$sn_" "$iid_"
            if empty_ "$k_"; then fin_ err
            elif [ "$(id_ "$k_/$sn_")" = "$iid_" ] || [ "$(id_ "$k_/$dn_")" = "$iid_" ]; then fin_ held
            else fin_ held_other; fi
            return
          fi
          if [ "$(id_ "./$dn_")" = "$iid_" ]; then fin_ ok; else fin_ err; fi
        }
        delete_() {
          i_="$1"; h_="$2"; e_="$3"; k_="$br_/$1"
          if ! after_ "$h_"; then report_ "$i_" skip; return; fi
          if [ "$7" = - ]; then
            if { pin_ "$4" "$5" && ! at_ "./$6"; } || ! at_ "$4"; then report_ "$i_" ok; else report_ "$i_" err; fi
            return
          fi
          if [ "$bok_" != 1 ]; then report_ "$i_" err; return; fi
          take_ "$4" "$5" "$6" "$7" "$e_"
          if [ "$t_" = gone ]; then fin_ ok; return; fi
          if [ "$t_" != ok ]; then fin_ "$t_"; return; fi
          /bin/rm -rfx -- "$k_/$6" >/dev/null 2>&1
          if at_ "$k_/$6"; then fin_ err; else fin_ ok; fi
        }
        """#

    /// The one line that runs this step.
    private static func call(
        for step: AdminStep, at index: Int, plan: StepPlan?, bridge: PlannedBridge?, isTrash: (String) -> Bool
    ) -> String {
        var head = "-"
        if let dependsOn = step.dependsOn {
            guard (0..<index).contains(dependsOn) else { return "report_ \(index) skip" }
            head = String(dependsOn)
        }
        let refused = "report_ \(index) err"
        var unsafe = "report_ \(index) unsafe"
        let expected = step.expectedSource?.stamp ?? "-"
        switch step.op {
        case .move(let from, let to, let bootOutDaemon):
            guard let source = AdminPath(from), let destination = AdminPath(to) else { return refused }
            // Out of the Trash: a Put back, whose refusal points to Finder's Put Back.
            if isTrash(source.folder) { unsafe = "report_ \(index) unsafe_putback" }
            guard let plan else { return unsafe }
            if plan.sourceGone { return "gone_ \(index) \(head)" }
            guard let sourceFolder = plan.source else { return unsafe }
            guard let item = plan.item else { return "gone_ \(index) \(head)" }
            // Every rename stays on the bridge's volume (a rename across volumes fails; the script also
            // checks right before each rename).
            guard let bridge, [item.device, sourceFolder.identity.device, plan.folder.identity.device]
                .allSatisfy({ $0 == bridge.device })
            else { return unsafe }
            // launchctl reads the plist by its path: only through a root-only chain.
            if bootOutDaemon && !sourceFolder.rootOnlyChain { return unsafe }
            // Into a folder the user can't write, only the item Put back recorded.
            if !plan.folder.userCanWrite && step.expectedSource == nil { return unsafe }
            if let expectedSource = step.expectedSource, expectedSource != item { return refused }
            let sameName = Array(source.name.utf8) == Array(destination.name.utf8)
            return ["move_", String(index), head, bootOutDaemon ? "1" : "0", expected, sameName ? "1" : "0",
                    quote(source.folder), sourceFolder.identity.stamp, quote(source.name), item.stamp,
                    quote(destination.folder), plan.folder.identity.stamp, quote(destination.name)]
                .joined(separator: " ")
        case .delete(let url):
            guard let item = AdminPath(url) else { return refused }
            guard let plan else { return unsafe }
            let fields = ["delete_", String(index), head, expected, quote(item.folder), plan.folder.identity.stamp,
                          quote(item.name)]
            guard let identity = plan.item else { return (fields + ["-"]).joined(separator: " ") }
            guard let bridge, identity.device == bridge.device, plan.folder.identity.device == bridge.device
            else { return unsafe }
            if let expectedSource = step.expectedSource, expectedSource != identity { return refused }
            return (fields + [identity.stamp]).joined(separator: " ")
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
/// can add, rename or remove entries in any of them, or change their permissions to do so. Used for
/// the bridge's parent (`/Library`) and for the plist folder of a `bootOutDaemon` move.
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
