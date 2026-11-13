import Foundation
import Security

/// Where the running copy of Dustling lives, as far as the Full Disk Access advice cares.
public enum RunningLocation: Equatable, Sendable {
    case applications, translocated, diskImage, elsewhere
}

/// What makes this copy of Dustling the "same app" to macOS. Full Disk Access is kept per designated
/// requirement, so a copy with a different one is refused even when System Settings shows a Dustling
/// switched on.
public enum CodeIdentity {
    /// The running code's designated requirement as text, or nil when it can't be read.
    public static func currentDesignatedRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// An Applications folder is `/Applications`, `~/Applications` (`home`'s), or one on another disk
    /// (`/Volumes/<disk>/Applications`, at any depth there). Anything else under `/Volumes` is taken
    /// for the disk image Dustling came on.
    public static func runningLocation(
        bundleURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> RunningLocation {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return .translocated }
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent().path
        let userApplications = home.standardizedFileURL.appending(path: "Applications").path
        if parent == "/Applications" || parent == userApplications { return .applications }
        if path.hasPrefix("/Volumes/") {
            let parts = path.dropFirst("/Volumes/".count).split(separator: "/", omittingEmptySubsequences: true)
            return parts.count > 2 && parts[1] == "Applications" ? .applications : .diskImage
        }
        return .elsewhere
    }
}
