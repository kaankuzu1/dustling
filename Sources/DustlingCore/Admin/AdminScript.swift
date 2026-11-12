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
    /// Index of an earlier step that must have succeeded for this one to run (an app's leftovers
    /// depend on the app). Anything other than an earlier index keeps the step from running.
    public let dependsOn: Int?

    public init(op: AdminOp, dependsOn: Int? = nil) {
        self.op = op
        self.dependsOn = dependsOn
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
/// Safety: each path is written once, single-quoted (`'` → `'\''`), into a variable (`src`, `dst`,
/// `item`) that is only ever used double-quoted, so the shell never expands, splits or globs
/// anything from a name. Tools get `--` before paths and have absolute paths; nothing is evaluated;
/// paths never appear in comments or output. A path that is not absolute, is `/`, has a `.` or `..`
/// component or a NUL byte never reaches a tool: its step just reports `err`.
public enum AdminScript {
    public static let goneReason = "already gone"
    public static let skippedReason = "kept because the app itself was not removed"
    public static let existsReason = "something with the same name is already there"
    public static let refusedReason = "macOS refused, even with your password"
    public static let noResultReason = "no result"

    public static func make(_ steps: [AdminStep]) -> String {
        var lines = [
            "set +e",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "export PATH",
        ]
        for (index, step) in steps.enumerated() {
            lines.append("# step \(index)")
            lines.append("s\(index)=0")
            lines += body(of: step, at: index)
            lines.append("if [ \"$r\" = ok ]; then s\(index)=1; fi")
            lines.append("printf 'R\\t\(index)\\t%s\\n' \"$r\"")
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

    /// The lines that set `r` to this step's status. Something exists when `-e` (it, or what a link
    /// points to) or `-L` (a link, even a dangling one) says so.
    private static func body(of step: AdminStep, at index: Int) -> [String] {
        var branches: [(test: String, status: String)] = []
        if let head = step.dependsOn {
            guard (0..<index).contains(head) else { return ["r=skip"] }
            branches.append(("[ \"$s\(head)\" != 1 ]", "skip"))
        }
        switch step.op {
        case .move(let from, let to, let bootOutDaemon):
            guard let source = quotedPath(from), let destination = quotedPath(to) else { return ["r=err"] }
            let sourceExists = #"{ [ -e "$src" ] || [ -L "$src" ]; }"#
            let destinationExists = #"{ [ -e "$dst" ] || [ -L "$dst" ]; }"#
            branches.append(("! \(sourceExists)", "gone"))
            branches.append((destinationExists, "exists"))
            var action: [String] = []
            if bootOutDaemon {
                action.append(#"/bin/launchctl bootout system "$src" >/dev/null 2>&1"#)
            }
            action.append(#"/bin/mv -n -- "$src" "$dst" >/dev/null 2>&1"#)
            action.append("if ! \(sourceExists) && \(destinationExists); then r=ok; else r=err; fi")
            return ["src=\(source)", "dst=\(destination)"] + chain(branches, otherwise: action)
        case .delete(let url):
            guard let item = quotedPath(url) else { return ["r=err"] }
            return ["item=\(item)"] + chain(branches, otherwise: [
                #"/bin/rm -rf -- "$item" >/dev/null 2>&1"#,
                #"if [ -e "$item" ] || [ -L "$item" ]; then r=err; else r=ok; fi"#,
            ])
        }
    }

    private static func chain(_ branches: [(test: String, status: String)], otherwise: [String]) -> [String] {
        guard !branches.isEmpty else { return otherwise }
        var lines: [String] = []
        for (position, branch) in branches.enumerated() {
            lines.append("\(position == 0 ? "if" : "elif") \(branch.test); then")
            lines.append("  r=\(branch.status)")
        }
        lines.append("else")
        lines += otherwise.map { "  " + $0 }
        lines.append("fi")
        return lines
    }

    /// The path single-quoted for sh, or nil when a root script must never touch it. Trailing
    /// slashes are dropped so a symlink is acted on itself, never followed to its target.
    static func quotedPath(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/"), path != "/", !path.contains("\0") else { return nil }
        let components = path.split(separator: "/")
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return quote(path)
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
