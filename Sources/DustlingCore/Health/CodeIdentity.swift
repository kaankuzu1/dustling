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

    public static func runningLocation(bundleURL: URL) -> RunningLocation {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path
        if parent == "/Applications" || parent == userApplications { return .applications }
        return .elsewhere
    }
}
