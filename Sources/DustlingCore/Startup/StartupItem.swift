import Foundation

public enum StartupScope: String, Codable, Sendable {
    case loginItem, userAgent, systemAgent, systemDaemon
}

/// One thing that launches at login or runs in the background.
public struct StartupItem: Identifiable, Hashable, Sendable {
    public var label: String
    public var scope: StartupScope
    public var plistURL: URL?
    public var program: String?
    public var ownerAppName: String?
    public var isEnabled: Bool
    /// True when the only way to change this item is System Settings > Login Items.
    public var managedInSystemSettingsOnly: Bool

    public var id: String { "\(scope.rawValue):\(plistURL?.path(percentEncoded: false) ?? label)" }

    public init(
        label: String,
        scope: StartupScope,
        plistURL: URL?,
        program: String?,
        ownerAppName: String?,
        isEnabled: Bool,
        managedInSystemSettingsOnly: Bool
    ) {
        self.label = label
        self.scope = scope
        self.plistURL = plistURL
        self.program = program
        self.ownerAppName = ownerAppName
        self.isEnabled = isEnabled
        self.managedInSystemSettingsOnly = managedInSystemSettingsOnly
    }
}
