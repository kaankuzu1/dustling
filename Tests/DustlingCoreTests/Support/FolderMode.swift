import Foundation
@testable import DustlingCore

/// Sets a folder's permission bits. Tests lock a folder (0555) so its items need admin, and open it
/// again in a `UserShell.beforeRun`, after planning and before the script runs, so the script (run
/// as the user) can do what root would. Always unlock in a `defer` too: the sandbox can't remove a
/// locked folder's contents.
enum FolderMode {
    static func set(_ url: URL, _ mode: mode_t) {
        _ = chmod(AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false)), mode)
    }

    static func lock(_ url: URL) { set(url, 0o555) }

    static func unlock(_ url: URL) { set(url, 0o755) }
}
