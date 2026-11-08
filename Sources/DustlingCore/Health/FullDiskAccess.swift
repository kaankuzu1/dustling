import Foundation

public enum FullDiskAccessStatus: Equatable, Sendable {
    case granted, denied, unknown
}

/// Verifies Full Disk Access by actually opening protected locations. Never trusts a stored flag.
public struct FullDiskAccessProbe: Sendable {
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private let environment: SystemEnvironment

    public init(environment: SystemEnvironment) {
        self.environment = environment
    }

    private enum Target {
        case file(URL)
        case directory(URL)
    }

    /// In order: the user's and the system's `TCC.db` (opened read-only and closed at once), then
    /// `~/Library/Safari`, `~/Library/Mail` and `~/Library/Messages` (opened as directories and closed
    /// at once). Contents are never read, and no other app's container is ever touched (that could
    /// trigger a consent prompt). macOS 26 has no per-user `TCC.db`, so the later targets matter.
    private var targets: [Target] {
        let lib = environment.userLibrary
        return [
            .file(lib.appending(path: "Application Support/com.apple.TCC/TCC.db")),
            .file(environment.systemLibrary.appending(path: "Application Support/com.apple.TCC/TCC.db")),
            .directory(lib.appending(path: "Safari")),
            .directory(lib.appending(path: "Mail")),
            .directory(lib.appending(path: "Messages")),
        ]
    }

    /// The first decisive target wins: success means granted, EPERM/EACCES means denied. Any other
    /// error (including a missing target) moves on to the next one; if none decides, `.unknown`.
    public func status() -> FullDiskAccessStatus {
        for target in targets {
            switch Self.probe(target) {
            case 0: return .granted
            case EPERM, EACCES: return .denied
            default: continue
            }
        }
        return .unknown
    }

    /// Returns 0 on success, otherwise the errno of the failed open.
    private static func probe(_ target: Target) -> Int32 {
        switch target {
        case .file(let url):
            // O_NONBLOCK so an unexpected FIFO can't hang the probe.
            let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return errno }
            close(fd)
            return 0
        case .directory(let url):
            guard let dir = opendir(url.path(percentEncoded: false)) else { return errno }
            closedir(dir)
            return 0
        }
    }
}
