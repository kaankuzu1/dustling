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
        "Library/Mobile Documents", "Library/Keychains", "Library/Mail",
    ]

    private let denied: [[String]]
    private let home: [String]
    private let usersRoot: [String]

    public init(environment: SystemEnvironment) {
        home = Self.key(Self.resolve(environment.home))
        usersRoot = Self.key(Self.resolve(URL(filePath: "/Users")))
        let entries = Self.systemDenied.map { URL(filePath: $0) }
            + Self.homeDenied.map { environment.home.appending(path: $0) }
        var list: [[String]] = []
        for entry in entries {
            list.append(Self.key(Self.resolve(entry)))
            // A symlinked entry stays protected where its files really live.
            if let real = Self.realpathString(entry.path(percentEncoded: false)) {
                list.append(Self.key(real.split(separator: "/").map(String.init)))
            }
        }
        denied = list
    }

    public func verdict(for url: URL, allowedRoots: [URL]) -> PathVerdict {
        let path = Self.key(Self.resolve(url))
        if denied.contains(where: { Self.isEqualOrInside(path, $0) }) {
            return .denied(reason: "protected location")
        }
        if Self.isStrictlyInside(path, usersRoot), !Self.isEqualOrInside(path, home) {
            return .denied(reason: "another user's files")
        }
        if allowedRoots.contains(where: { Self.isStrictlyInside(path, Self.key(Self.resolve($0))) }) {
            return .allowed
        }
        return .denied(reason: "outside the cleanup area")
    }

    // MARK: - Path handling

    /// Case- and normalization-folded components, so `documents` and `Documentſ` match `Documents`
    /// on case-insensitive volumes. Over-denying is the safe direction.
    private static func key(_ comps: [String]) -> [String] {
        comps.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
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
