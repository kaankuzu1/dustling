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
    /// scanned or moved, and neither is anything that contains one.
    public var exclusions: [String]

    public init(skipChangedWithinDays: Int? = nil, includeExternalTrash: Bool = true, exclusions: [String] = []) {
        self.skipChangedWithinDays = skipChangedWithinDays
        self.includeExternalTrash = includeExternalTrash
        self.exclusions = exclusions
    }

    /// The exclusions as standardized absolute URLs. Empty, whitespace-only and relative entries (after
    /// expanding a leading `~` against `home`) are ignored rather than guessed at.
    public func exclusionURLs(home: URL) -> [URL] {
        exclusions.compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded: String
            if text == "~" {
                expanded = home.path(percentEncoded: false)
            } else if text.hasPrefix("~/") {
                expanded = home.appending(path: String(text.dropFirst(2))).path(percentEncoded: false)
            } else {
                expanded = text
            }
            guard expanded.hasPrefix("/") else { return nil }
            var path = URL(filePath: expanded).standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return URL(filePath: path)
        }
    }

    /// The single place that turns options into the guard used by cleaning and uninstalling.
    public func protectedPaths(environment: SystemEnvironment) -> ProtectedPaths {
        ProtectedPaths(environment: environment, extraDenied: exclusionURLs(home: environment.home))
    }
}
