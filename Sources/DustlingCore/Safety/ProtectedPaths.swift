import Foundation

public enum PathVerdict: Equatable, Sendable {
    case allowed
    case denied(reason: String)
}

/// Decides whether a path may ever be moved to the Trash. Every comparison is done on
/// symlink-resolved parents (the item's own final component is never resolved, so a symlink is
/// judged by where the link lives) and by whole path components, never by string prefix.
public struct ProtectedPaths: Sendable {
    private static let systemDenied = ["/System", "/bin", "/sbin", "/usr", "/private/var/db", "/Library/Apple"]
    private static let homeDenied = [
        "Documents", "Desktop", "Pictures", "Music", "Movies",
        "Library/Mobile Documents", "Library/Keychains", "Library/Mail", "Library/CloudStorage",
    ]
    /// Denied themselves (by equality only): their children are decided by the rules below.
    private static let homeExactDenied = ["", "Library"]

    private let denied: [[String]]
    private let exactDenied: [[String]]
    private let home: [String]
    private let usersRoot: [String]

    public init(environment: SystemEnvironment) {
        home = Self.caseKey(Self.resolve(environment.home))
        usersRoot = Self.key(Self.resolve(URL(filePath: "/Users")))
        let entries = Self.systemDenied.map { URL(filePath: $0) }
            + Self.homeDenied.map { environment.home.appending(path: $0) }
        denied = Self.keys(for: entries)
        exactDenied = Self.keys(for: Self.homeExactDenied.map {
            $0.isEmpty ? environment.home : environment.home.appending(path: $0)
        })
    }

    /// Each entry as resolved like a candidate, plus (for a symlinked entry) where it really lives.
    private static func keys(for entries: [URL]) -> [[String]] {
        var list: [[String]] = []
        for entry in entries {
            list.append(key(resolve(entry)))
            if let real = realpathString(entry.path(percentEncoded: false)) {
                list.append(key(real.split(separator: "/").map(String.init)))
            }
        }
        return list
    }

    public func verdict(for url: URL, allowedRoots: [URL]) -> PathVerdict {
        let resolved = Self.resolve(url)
        let path = Self.key(resolved)
        let casePath = Self.caseKey(resolved)
        if denied.contains(where: { Self.isEqualOrInside(path, $0) }) || exactDenied.contains(path) {
            return .denied(reason: "protected location")
        }
        if Self.isStrictlyInside(path, usersRoot), !Self.isEqualOrInside(casePath, home) {
            return .denied(reason: "another user's files")
        }
        if allowedRoots.contains(where: { Self.isStrictlyInside(casePath, Self.caseKey(Self.resolve($0))) }) {
            return .allowed
        }
        return .denied(reason: "outside the cleanup area")
    }

    // MARK: - Path handling

    /// Broad fold (case, diacritics, width) for deny-list matching and `/Users` detection only:
    /// over-matching there denies more, which is the safe direction.
    private static func key(_ comps: [String]) -> [String] {
        comps.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
    }

    /// Case-only fold for "is this my own home" and "is this inside an allowed root": over-matching
    /// there would under-deny. APFS ignores case but not diacritics or width.
    private static func caseKey(_ comps: [String]) -> [String] {
        comps.map { $0.folding(options: [.caseInsensitive], locale: nil) }
    }

    private static func isEqualOrInside(_ path: [String], _ base: [String]) -> Bool {
        path.count >= base.count && Array(path.prefix(base.count)) == base
    }

    private static func isStrictlyInside(_ path: [String], _ base: [String]) -> Bool {
        path.count > base.count && Array(path.prefix(base.count)) == base
    }

    /// Resolves symlinks in everything but the final component and returns normalized components.
    /// A trailing `.` or `..` is not a real name, so in that case the whole path is resolved.
    private static func resolve(_ url: URL) -> [String] {
        let comps = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = comps.last else { return [] }
        if last == "." || last == ".." {
            return realpathOfExistingPrefix(comps)
        }
        return realpathOfExistingPrefix(Array(comps.dropLast())) + [last]
    }

    /// realpath the longest existing prefix, then append the remaining (non-existent) components
    /// and normalize `.`/`..` textually, which is safe because nothing there can be a symlink.
    private static func realpathOfExistingPrefix(_ comps: [String]) -> [String] {
        var existing = comps
        var rest: [String] = []
        while true {
            if let real = realpathString("/" + existing.joined(separator: "/")) {
                return normalize(real.split(separator: "/").map(String.init) + rest)
            }
            guard let tail = existing.popLast() else { return normalize(rest) }
            rest.insert(tail, at: 0)
        }
    }

    private static func realpathString(_ path: String) -> String? {
        guard let buffer = realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    private static func normalize(_ comps: [String]) -> [String] {
        var out: [String] = []
        for c in comps {
            if c == "." { continue }
            if c == ".." { _ = out.popLast(); continue }
            out.append(c)
        }
        return out
    }
}
