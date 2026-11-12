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
/// - When the script is made, the folder each step acts in (a move's destination folder, a
///   delete's item folder) is read with lstat. At run time the step `cd -P`s into it and acts on
///   `./<name>` only if it is still that same directory (device, inode, owner); a folder swapped for
///   a link or another folder makes the step `err`.
/// - A move reads the source's identity (lstat) and checks it is on the folder's volume and, when
///   given, is `expectedSource`; only then is a daemon booted out and the item moved, never
///   overwriting (`mv -n -h`).
///   - Into a folder the user can write (the Trash): the source goes straight to `./<name>` (as
///     `mv … .` when the name is the source's own, so mv never treats `./<name>` as a folder), and
///     the step is `ok` only if `./<name>` then has exactly the source's identity.
///   - Into a folder the user can't write (Put back): `expectedSource` is required, or the step is
///     `err` without running. The source is first renamed to a hidden temporary name inside the
///     pinned folder, where no one but root can touch it; it is published as `./<name>` only if
///     that staged item is exactly the expected one. Anything else is never published and never
///     moved back out by path: it is deleted when it is the user's own (only they could have put it
///     there) and otherwise left under the hidden name; the step is `err`.
/// - A path that is not absolute, is `/`, has a `.` or `..` component or a NUL byte (checked on
///   UTF-8 bytes), or whose folder is not a real directory, never reaches a tool: `err`.
public enum AdminScript {
    public static let goneReason = "already gone"
    public static let skippedReason = "kept because the app itself was not removed"
    public static let existsReason = "something with the same name is already there"
    public static let refusedReason = "macOS refused, even with your password"
    public static let noResultReason = "no result"

    /// Reads each step's folder now (planning time) and builds the script.
    public static func make(_ steps: [AdminStep]) -> String {
        make(steps, folders: steps.map(plannedFolder))
    }

    /// What planning learned about the folder a step acts in.
    struct PlannedFolder: Equatable {
        let identity: ItemIdentity
        /// Whether Dustling's user could change the folder (and so race root inside it).
        let userCanWrite: Bool
    }

    /// The folder a step acts in, if it is a real directory right now (lstat): the destination's
    /// folder for a move, the item's folder for a delete.
    static func plannedFolder(of step: AdminStep) -> PlannedFolder? {
        let target: URL
        switch step.op {
        case .move(_, let to, _): target = to
        case .delete(let url): target = url
        }
        guard let path = AdminPath(target),
              let identity = ItemIdentity.of(path: path.folder, directoryOnly: true)
        else { return nil }
        return PlannedFolder(identity: identity, userCanWrite: access(path.folder, W_OK) == 0)
    }

    /// `folders[i]` is what planning found for step i's folder (nil: not a real directory).
    /// `user` is the account Dustling runs as: only its own items may be deleted when staged by mistake.
    static func make(_ steps: [AdminStep], folders: [PlannedFolder?], user: uid_t = getuid()) -> String {
        var lines = [prelude, "me_=\(user)"]
        for (index, step) in steps.enumerated() {
            lines.append(call(for: step, at: index, folder: index < folders.count ? folders[index] : nil))
        }
        // A non-zero exit would make osascript throw away everything the script printed.
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
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
    /// - `move_ <index> <head|-> <bootout 0|1> <expected identity|-> <mode s|d|n> <source> <folder>
    ///   <folder identity> <name>`; mode `s` stages (folder the user can't write), `d` moves into the
    ///   folder under the source's own name, `n` moves to `./<name>`.
    /// - `delete_ <index> <head|-> <expected identity|-> <folder> <folder identity> <name>`
    /// `me_` (set after the functions) is the user Dustling runs as.
    static let prelude = #"""
        set +e
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        unset CDPATH
        ok_=' '
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
        move_() {
          if ! after_ "$2"; then report_ "$1" skip; return; fi
          if ! at_ "$6"; then report_ "$1" gone; return; fi
          if ! in_ "$7" "$8"; then report_ "$1" err; return; fi
          if at_ "./$9"; then report_ "$1" exists; return; fi
          was_=$(id_ "$6")
          if [ -z "$was_" ] || [ "${was_%%:*}" != "${8%%:*}" ]; then report_ "$1" err; return; fi
          if [ "$4" != - ] && [ "$was_" != "$4" ]; then report_ "$1" err; return; fi
          if [ "$3" = 1 ]; then /bin/launchctl bootout system "$6" >/dev/null 2>&1; fi
          case "$5" in
            s) stage_ "$1" "$4" "$6" "$9" ;;
            d) /bin/mv -n -h -- "$6" . >/dev/null 2>&1; landed_ "$1" "$6" "$9" ;;
            *) /bin/mv -n -h -- "$6" "./$9" >/dev/null 2>&1; landed_ "$1" "$6" "$9" ;;
          esac
        }
        landed_() {
          if [ "$(id_ "./$3")" = "$was_" ] && ! at_ "$2"; then report_ "$1" ok; else report_ "$1" err; fi
        }
        stage_() {
          tmp_=".dustling-$$-$1"
          if at_ "./$tmp_"; then report_ "$1" err; return; fi
          /bin/mv -n -h -- "$3" "./$tmp_" >/dev/null 2>&1
          got_=$(id_ "./$tmp_")
          if [ -z "$got_" ]; then report_ "$1" err; return; fi
          if [ "$got_" != "$was_" ] || { [ "$2" != - ] && [ "$got_" != "$2" ]; }; then
            case "$got_" in *":$me_") /bin/rm -rf -- "./$tmp_" >/dev/null 2>&1 ;; esac
            report_ "$1" err
            return
          fi
          /bin/mv -n -h -- "./$tmp_" "./$4" >/dev/null 2>&1
          if [ "$(id_ "./$4")" = "$was_" ] && ! at_ "./$tmp_"; then report_ "$1" ok; else report_ "$1" err; fi
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
    private static func call(for step: AdminStep, at index: Int, folder: PlannedFolder?) -> String {
        var head = "-"
        if let dependsOn = step.dependsOn {
            guard (0..<index).contains(dependsOn) else { return "report_ \(index) skip" }
            head = String(dependsOn)
        }
        let expected = step.expectedSource?.stamp ?? "-"
        switch step.op {
        case .move(let from, let to, let bootOutDaemon):
            guard let source = AdminPath(from), let destination = AdminPath(to), let folder else {
                return "report_ \(index) err"
            }
            let mode: String
            if !folder.userCanWrite {
                // Root only puts into a folder the user can't write what it can prove came from Put back.
                guard step.expectedSource != nil else { return "report_ \(index) err" }
                mode = "s"
            } else if Array(source.name.utf8) == Array(destination.name.utf8) {
                mode = "d"
            } else {
                // Residual: a numbered name ("name 2") must be given to mv as `./name 2`, which mv
                // treats as a folder to move into if one appears there at that instant.
                mode = "n"
            }
            return ["move_", String(index), head, bootOutDaemon ? "1" : "0", expected, mode,
                    quote(source.full), quote(destination.folder), folder.identity.stamp, quote(destination.name)]
                .joined(separator: " ")
        case .delete(let url):
            guard let item = AdminPath(url), let folder else { return "report_ \(index) err" }
            return ["delete_", String(index), head, expected, quote(item.folder), folder.identity.stamp,
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
