import Foundation

/// The scan settings the app exposes. One value builds both the catalog (what is scanned) and the
/// `ProtectedPaths` (what may ever be moved), so the two can never disagree about exclusions.
public struct ScanOptions: Codable, Equatable, Sendable {
    /// Items whose own modification date is within this many days of "now" are skipped. `nil` (or a
    /// value below 1) turns the rule off. For a directory this is the directory's own mdate, which
    /// changes when entries are added or removed but not when a nested file is edited: a cheap
    /// approximation, deliberately not a deep walk.
    public var skipChangedWithinDays: Int?
    /// Whether the Trash category also covers `<volumes>/*/.Trashes/<uid>`.
    public var includeExternalTrash: Bool
    /// User-entered absolute paths (a leading `~` is expanded). Everything inside one is never
    /// scanned or moved, and neither is anything that contains one. These guard what would be moved
    /// to the Trash; they never change what is already in the Trash (it is listed and emptied whole).
    public var exclusions: [String]

    public init(skipChangedWithinDays: Int? = nil, includeExternalTrash: Bool = true, exclusions: [String] = []) {
        self.skipChangedWithinDays = skipChangedWithinDays
        self.includeExternalTrash = includeExternalTrash
        self.exclusions = exclusions
    }

    /// Validates and normalizes raw exclusion entries: a leading `~` is expanded against `home`, the path
    /// is standardized and trailing slashes dropped. Entries that cannot be used are returned with why,
    /// so the Settings UI can tell the user.
    public static func normalizeExclusions(
        _ raw: [String], home: URL
    ) -> (accepted: [URL], ignored: [(entry: String, reason: String)]) {
        var accepted: [URL] = []
        var ignored: [(entry: String, reason: String)] = []
        for entry in raw {
            let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded: String
            if text.isEmpty { ignored.append((entry, "empty")); continue }
            if text.lowercased().hasPrefix("file://") { ignored.append((entry, "file URL not supported")); continue }
            if text == "~" {
                expanded = home.path(percentEncoded: false)
            } else if text.hasPrefix("~/") {
                expanded = home.appending(path: String(text.dropFirst(2))).path(percentEncoded: false)
            } else if text.hasPrefix("~") {
                ignored.append((entry, "unknown user")); continue
            } else {
                expanded = text
            }
            guard expanded.hasPrefix("/") else { ignored.append((entry, "not an absolute path")); continue }
            var path = URL(filePath: expanded).standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            accepted.append(URL(filePath: path))
        }
        return (accepted, ignored)
    }

    /// The usable exclusions as standardized absolute URLs (see `normalizeExclusions`).
    public func exclusionURLs(home: URL) -> [URL] {
        Self.normalizeExclusions(exclusions, home: home).accepted
    }

    /// Missing fields take their defaults, so older or partial saved settings still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skipChangedWithinDays = try c.decodeIfPresent(Int.self, forKey: .skipChangedWithinDays)
        includeExternalTrash = try c.decodeIfPresent(Bool.self, forKey: .includeExternalTrash) ?? true
        exclusions = try c.decodeIfPresent([String].self, forKey: .exclusions) ?? []
    }

    private enum CodingKeys: String, CodingKey { case skipChangedWithinDays, includeExternalTrash, exclusions }

    /// The single place that turns options into the guard used by cleaning and uninstalling.
    public func protectedPaths(environment: SystemEnvironment) -> ProtectedPaths {
        ProtectedPaths(environment: environment, extraDenied: exclusionURLs(home: environment.home))
    }
}
