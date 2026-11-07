import Foundation

public enum LeftoverKind: String, Codable, Sendable {
    case applicationSupport, caches, preferences, container, groupContainer, savedState, httpStorage
    case webKit, logs, cookies, launchAgent, launchDaemon, privilegedHelper, packageReceipt
    case steamGameData
}

public enum MatchStrength: Sendable {
    case exact, nameBased
}

public struct Leftover: Identifiable, Hashable, Sendable {
    public var url: URL
    public var kind: LeftoverKind
    public var match: MatchStrength
    public var mayContainUserData: Bool
    public var requiresAdmin: Bool
    public var bytes: UInt64

    public var id: URL { url }

    /// Only exact matches of disposable data start checked; anything that may hold the user's own
    /// data is listed but left for the user to opt in.
    public var preselected: Bool { match == .exact && !mayContainUserData }

    public init(
        url: URL, kind: LeftoverKind, match: MatchStrength, mayContainUserData: Bool,
        requiresAdmin: Bool, bytes: UInt64
    ) {
        self.url = url
        self.kind = kind
        self.match = match
        self.mayContainUserData = mayContainUserData
        self.requiresAdmin = requiresAdmin
        self.bytes = bytes
    }
}
