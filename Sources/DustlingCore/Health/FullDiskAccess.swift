import Foundation

public enum FullDiskAccessStatus: Equatable, Sendable {
    case granted, denied, unknown
}

/// Verifies Full Disk Access by actually opening a protected file. Never trusts a stored flag.
public struct FullDiskAccessProbe: Sendable {
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private let environment: SystemEnvironment

    public init(environment: SystemEnvironment) {
        self.environment = environment
    }

    /// Opens (and immediately closes) `~/Library/Application Support/com.apple.TCC/TCC.db`
    /// read-only. The contents are never read.
    public func status() -> FullDiskAccessStatus {
        let path = environment.home
            .appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        switch errno {
        case EPERM, EACCES: return .denied
        default: return .unknown   // ENOENT or anything unexpected: can't tell
        }
    }
}
