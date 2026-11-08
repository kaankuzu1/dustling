import Foundation
import os

/// The user's exclusions as they are right now. Settings changes them while Dustling runs, and every
/// `ProtectedPaths` built with this object follows at once, so the guard used by the mover can never
/// lag behind what Settings shows. Keys are computed when the list is set, not per verdict.
public final class LiveExclusions: Sendable {
    private let keys: OSAllocatedUnfairLock<[[String]]>

    /// `textualUnder`: folders (the consent folders without Full Disk Access) whose exclusions are
    /// keyed by their text only, so setting them never reads inside a folder that could prompt.
    public init(_ urls: [URL], textualUnder: [URL] = []) {
        keys = OSAllocatedUnfairLock(initialState: ProtectedPaths.keys(for: urls, textualUnder: textualUnder))
    }

    public func set(_ urls: [URL], textualUnder: [URL] = []) {
        let new = ProtectedPaths.keys(for: urls, textualUnder: textualUnder)
        keys.withLock { $0 = new }
    }

    var current: [[String]] { keys.withLock { $0 } }
}

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
    private let fixedExcluded: [[String]]
    private let liveExclusions: LiveExclusions?
    private var excluded: [[String]] { fixedExcluded + (liveExclusions?.current ?? []) }

    static let excludedReason = "excluded in Settings"
    static let containsExcludedReason = "contains a folder excluded in Settings"

    /// `extraDenied` are the user's exclusions: anything equal to or inside one is denied, and so is
    /// anything that contains one (moving a parent would take the excluded folder with it). Hard denies
    /// are decided first, so an exclusion on a protected location changes nothing there.
    /// `liveExclusions` adds exclusions that can change after this value was built (Settings).
    /// `textualUnder`: exclusions equal to or inside these folders are keyed textually (see `keys`).
    public init(
        environment: SystemEnvironment, extraDenied: [URL] = [], liveExclusions: LiveExclusions? = nil,
        textualUnder: [URL] = []
    ) {
        home = Self.caseKey(Self.resolve(environment.home))
        usersRoot = Self.key(Self.resolve(URL(filePath: "/Users")))
        let entries = Self.systemDenied.map { URL(filePath: $0) }
            + Self.homeDenied.map { environment.home.appending(path: $0) }
        denied = Self.keys(for: entries)
        exactDenied = Self.keys(for: Self.homeExactDenied.map {
            $0.isEmpty ? environment.home : environment.home.appending(path: $0)
        })
        fixedExcluded = Self.keys(for: extraDenied, textualUnder: textualUnder)
        self.liveExclusions = liveExclusions
    }

    /// Why `url` is off limits because of a user exclusion, or nil. Same resolution and fold as the
    /// hard-deny list.
    public func exclusionReason(for url: URL) -> String? {
        let excluded = self.excluded
        guard !excluded.isEmpty else { return nil }
        let path = Self.key(Self.resolve(url))
        if excluded.contains(where: { Self.isEqualOrInside(path, $0) }) { return Self.excludedReason }
        if excluded.contains(where: { Self.isStrictlyInside($0, path) }) { return Self.containsExcludedReason }
        return nil
    }

    /// Each entry as resolved like a candidate, plus (for a symlinked entry) where it really lives.
    /// Paths under the Data volume's firmlink prefix also get the form without it, because realpath
    /// does not map a firmlink back (`/System/Volumes/Data/Users/x` is the same place as `/Users/x`).
    ///
    /// Entries equal to or inside a `textualUnder` folder are keyed by their text only: no realpath and
    /// no lstat, because without Full Disk Access looking inside a consent folder (Downloads,
    /// Containers) can raise a macOS prompt. `realpath` is injectable for tests.
    static func keys(
        for entries: [URL], textualUnder: [URL] = [],
        realpath: (String) -> String? = { ProtectedPaths.realpathString($0) }
    ) -> [[String]] {
        var list: [[String]] = []
        let textual = textualUnder.map(textualComponents)
        func resolve(_ url: URL) -> [String] { Self.resolve(url, realpath: realpath) }
        func add(_ comps: [String]) {
            list.append(key(comps))
            // The stripped form is resolved again: it may still go through symlinks (e.g. /var).
            if let stripped = withoutDataVolumePrefix(comps) {
                list.append(key(resolve(URL(filePath: "/" + stripped.joined(separator: "/")))))
            }
        }
        for entry in entries {
            let text = textualComponents(entry)
            if let index = textual.firstIndex(where: { isEqualOrInside(text, $0) }) {
                // The consent folder itself may be resolved (that reads only its parent), so the key
                // matches candidates whose parents were resolved; nothing inside it is looked at.
                let folder = textualUnder[index]
                let rest = Array(text.dropFirst(textual[index].count))
                let folderReal = realpath(folder.path(percentEncoded: false))
                    .map { $0.split(separator: "/").map(String.init) } ?? resolve(folder)
                list.append(key(text))
                list.append(key(folderReal + rest))
                continue
            }
            add(resolve(entry))
            if let real = realpath(entry.path(percentEncoded: false)) {
                add(real.split(separator: "/").map(String.init))
            }
        }
        return list
    }

    static func withoutDataVolumePrefix(_ comps: [String]) -> [String]? {
        let prefix = ["System", "Volumes", "Data"]
        guard comps.count > prefix.count, Array(comps.prefix(3)) == prefix else { return nil }
        return Array(comps.dropFirst(3))
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
        if let reason = exclusionReason(for: url) { return .denied(reason: reason) }
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
    private static func resolve(
        _ url: URL, realpath: (String) -> String? = { ProtectedPaths.realpathString($0) }
    ) -> [String] {
        let comps = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = comps.last else { return [] }
        if last == "." || last == ".." {
            return realpathOfExistingPrefix(comps, realpath: realpath)
        }
        return realpathOfExistingPrefix(Array(comps.dropLast()), realpath: realpath) + [last]
    }

    /// The path's components with `.` and `..` folded, without touching the disk.
    static func textualComponents(_ url: URL) -> [String] {
        normalize(url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true).map(String.init))
    }

    /// True when `url` may not be excluded because Dustling never touches it or anything inside it
    /// anyway: a protected folder tree (Documents, /System, …) or another user's files. The home folder
    /// and ~/Library themselves can be excluded (only they are protected, not what's inside).
    public func isProtectedTree(_ url: URL) -> Bool {
        let resolved = Self.resolve(url)
        let path = Self.key(resolved)
        if denied.contains(where: { Self.isEqualOrInside(path, $0) }) { return true }
        return Self.isStrictlyInside(path, usersRoot) && !Self.isEqualOrInside(Self.caseKey(resolved), home)
    }

    /// realpath the longest existing prefix, then append the remaining (non-existent) components
    /// and normalize `.`/`..` textually, which is safe because nothing there can be a symlink.
    private static func realpathOfExistingPrefix(
        _ comps: [String], realpath: (String) -> String? = { ProtectedPaths.realpathString($0) }
    ) -> [String] {
        var existing = comps
        var rest: [String] = []
        while true {
            if let real = realpath("/" + existing.joined(separator: "/")) {
                return normalize(real.split(separator: "/").map(String.init) + rest)
            }
            guard let tail = existing.popLast() else { return normalize(rest) }
            rest.insert(tail, at: 0)
        }
    }

    static func realpathString(_ path: String) -> String? {
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
