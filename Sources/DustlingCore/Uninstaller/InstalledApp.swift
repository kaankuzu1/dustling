import Foundation

/// An application bundle found on disk. `bundleID` is nil for wrappers (e.g. Steam launchers)
/// whose Info.plist has no `CFBundleIdentifier`.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var url: URL
    public var displayName: String
    public var bundleID: String?
    public var teamID: String?
    public var executableName: String?
    public var steamAppID: String?
    /// Size on disk. For a symlinked `.app` this is the target's size when the target is readable
    /// (removing the link frees almost nothing; see `linkTarget`).
    public var bytes: UInt64
    public var lastUsed: Date?
    /// Where the `.app` entry points when it is a symbolic link (fully resolved). Uninstalling such an
    /// app removes only the link; the app itself stays where it is.
    public var linkTarget: URL?

    public var id: URL { url }

    public init(
        url: URL,
        displayName: String,
        bundleID: String?,
        teamID: String?,
        executableName: String?,
        steamAppID: String?,
        bytes: UInt64,
        lastUsed: Date?,
        linkTarget: URL? = nil
    ) {
        self.url = url
        self.displayName = displayName
        self.bundleID = bundleID
        self.teamID = teamID
        self.executableName = executableName
        self.steamAppID = steamAppID
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.linkTarget = linkTarget
    }
}
