import Foundation
import Security

/// Finds installed applications in the configured application directories.
public struct AppScout: Sendable {
    private static let maxDepth = 3
    private static let maxScriptBytes = 64 * 1024

    private let environment: SystemEnvironment
    private let sizer: DirectorySizer
    private let measuresSizes: Bool

    /// `measuresSizes: false` lists the apps without measuring them (`bytes` is 0), for callers that
    /// only need names and locations, such as the owners of startup items.
    public init(environment: SystemEnvironment, sizer: DirectorySizer = DirectorySizer(), measuresSizes: Bool = true) {
        self.environment = environment
        self.sizer = sizer
        self.measuresSizes = measuresSizes
    }

    /// Installed apps sorted by display name (case-insensitive).
    public func discover() -> [InstalledApp] {
        discoverWithIssues().apps
    }

    /// Like `discover()`, but also reports directories that could not be read.
    public func discoverWithIssues() -> (apps: [InstalledApp], unreadable: [URL]) {
        var found: [InstalledApp] = []
        var unreadable: [URL] = []
        var seen = Set<String>()
        for root in environment.applicationDirectories {
            if Self.isInsideSystemApplications(root) { continue }
            search(root, depth: 1, apps: &found, unreadable: &unreadable, seen: &seen)
        }
        found.sort {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
        return (found, unreadable)
    }

    // MARK: - Search

    private func search(
        _ directory: URL, depth: Int, apps: inout [InstalledApp],
        unreadable: inout [URL], seen: inout Set<String>
    ) {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [])
        } catch {
            if !Self.isMissing(error) { unreadable.append(directory) }
            return
        }
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let isLink = values?.isSymbolicLink ?? false
            let isApp = entry.pathExtension.lowercased() == "app"
            if isApp {
                let resolved = entry.resolvingSymlinksInPath()
                if Self.isInsideSystemApplications(resolved) || (isLink && resolved.path.hasPrefix("/System/")) {
                    continue
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue
                else { continue }
                guard seen.insert(entry.path).inserted else { continue }
                apps.append(makeApp(entry, linkTarget: isLink ? resolved : nil))
            } else if !isLink, values?.isDirectory == true, depth < Self.maxDepth {
                search(entry, depth: depth + 1, apps: &apps, unreadable: &unreadable, seen: &seen)
            }
        }
    }

    /// True when the failure means the directory does not exist (ENOENT/ENOTDIR), judged from the
    /// POSIX error behind the Cocoa error, like the junk scanner.
    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        var posix: Int32?
        if error.domain == NSPOSIXErrorDomain { posix = Int32(error.code) }
        if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            posix = Int32(under.code)
        }
        if let posix { return posix == ENOENT || posix == ENOTDIR }
        return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
    }

    private static func isInsideSystemApplications(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return path == "/System/Applications" || path.hasPrefix("/System/Applications/")
    }

    // MARK: - Metadata

    /// `linkTarget` is set when the `.app` entry is a symbolic link; metadata and size then come from
    /// the target (the link itself occupies next to nothing).
    private func makeApp(_ url: URL, linkTarget: URL?) -> InstalledApp {
        let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
        func string(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        let executable = string("CFBundleExecutable")
        let lastUsed = try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
        return InstalledApp(
            url: url,
            displayName: string("CFBundleDisplayName") ?? string("CFBundleName") ?? fileName,
            bundleID: string("CFBundleIdentifier"),
            teamID: teamIdentifier(of: url),
            executableName: executable,
            steamAppID: executable.flatMap { steamAppID(in: url.appending(path: "Contents/MacOS/\($0)")) },
            bytes: measuresSizes ? sizer.measure(linkTarget ?? url).bytes : 0,
            lastUsed: lastUsed,
            linkTarget: linkTarget
        )
    }

    private func steamAppID(in executable: URL) -> String? {
        guard let values = try? executable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= Self.maxScriptBytes,
              let data = try? Data(contentsOf: executable),
              let text = String(data: data, encoding: .utf8),
              let match = text.firstMatch(of: /steam:\/\/run\/(\d+)/)
        else { return nil }
        return String(match.1)
    }

    private func teamIdentifier(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
