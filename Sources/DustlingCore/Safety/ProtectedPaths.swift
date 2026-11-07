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
        let resolvedHome = Self.resolve(environment.home)
        home = resolvedHome
        usersRoot = Self.resolve(URL(filePath: "/Users"))
        let homeEntries = Self.homeDenied.map { resolvedHome + $0.split(separator: "/").map(String.init) }
        denied = Self.systemDenied.map { Self.resolve(URL(filePath: $0)) } + homeEntries
    }

    public func verdict(for url: URL, allowedRoots: [URL]) -> PathVerdict {
        let path = Self.resolve(url)
        if denied.contains(where: { Self.isEqualOrInside(path, $0) }) {
            return .denied(reason: "protected location")
        }
        if Self.isStrictlyInside(path, usersRoot), !Self.isEqualOrInside(path, home) {
            return .denied(reason: "another user's files")
        }
        if allowedRoots.contains(where: { Self.isStrictlyInside(path, Self.resolve($0)) }) {
            return .allowed
        }
        return .denied(reason: "outside the cleanup area")
    }

    // MARK: - Path handling

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
