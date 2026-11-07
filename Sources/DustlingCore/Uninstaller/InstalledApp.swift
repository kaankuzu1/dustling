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
    public var bytes: UInt64
    public var lastUsed: Date?

    public var id: URL { url }

    public init(
        url: URL,
        displayName: String,
        bundleID: String?,
        teamID: String?,
        executableName: String?,
        steamAppID: String?,
        bytes: UInt64,
        lastUsed: Date?
    ) {
        self.url = url
        self.displayName = displayName
        self.bundleID = bundleID
        self.teamID = teamID
        self.executableName = executableName
        self.steamAppID = steamAppID
        self.bytes = bytes
        self.lastUsed = lastUsed
    }
}
