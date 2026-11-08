import Foundation
import Security

/// Finds installed applications in the configured application directories.
public struct AppScout: Sendable {
    private static let maxDepth = 3
    private static let maxScriptBytes = 64 * 1024

    private let environment: SystemEnvironment
    private let sizer: DirectorySizer
    private let measuresSizes: Bool
    /// The folders to skip as folded path components, both as given and with their parent's links
    /// resolved (so `/var/…` and `/private/var/…` both match).
    private let skipping: [[String]]

    /// `measuresSizes: false` lists the apps without measuring them (`bytes` is 0), for callers that
    /// only need names and locations, such as the owners of startup items. Apps linked into
    /// `skipping` (folders that ask for consent without Full Disk Access) are left out, and nothing
    /// inside those folders is ever looked at: links are resolved by hand, one component at a time.
    public init(
        environment: SystemEnvironment, sizer: DirectorySizer = DirectorySizer(), measuresSizes: Bool = true,
        skipping: [URL] = []
    ) {
        self.environment = environment
        self.sizer = sizer
        self.measuresSizes = measuresSizes
        var forms: [[String]] = []
        for folder in skipping {
            let path = folder.standardizedFileURL.path(percentEncoded: false)
            forms.append(Self.folded(path))
            // The folder's parent may go through links; only the parent is looked at, never the folder.
            let parent = (path as NSString).deletingLastPathComponent
            if let real = Self.resolveLinks(parent, skipping: [], isLink: Self.isLink, readLink: Self.readLink) {
                let form = Self.folded(real) + [Self.fold((path as NSString).lastPathComponent)]
                if !forms.contains(form) { forms.append(form) }
            }
        }
        self.skipping = forms
    }

    // MARK: - Links, resolved without opening skipped folders

    static let maxLinkHops = 32

    private static func fold(_ component: String) -> String {
        component.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func folded(_ path: String) -> [String] {
        path.split(separator: "/").map { fold(String($0)) }
    }

    private static func isInside(_ components: [String], _ skipping: [[String]]) -> Bool {
        let parts = components.map(fold)
        return skipping.contains { !$0.isEmpty && parts.count >= $0.count && Array(parts.prefix($0.count)) == $0 }
    }

    private static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func readLink(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// Resolves every link in the absolute `path`, one component at a time. Each prefix is checked
    /// against `skipping` before `isLink` or `readLink` sees it, and a link's target is spliced in
    /// (relative to the folder holding it) before going on. `..` applies to the resolved folder.
    /// Nil when the path leads into a skipped folder, a link can't be read, or it takes more than
    /// `maxHops` links (a loop).
    static func resolveLinks(
        _ path: String, skipping: [[String]], isLink: (String) -> Bool, readLink: (String) -> String?,
        maxHops: Int = maxLinkHops
    ) -> String? {
        var resolved: [String] = []
        var remaining = path.split(separator: "/").map(String.init)
        var hops = 0
        while !remaining.isEmpty {
            let component = remaining.removeFirst()
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            let candidate = resolved + [component]
            if isInside(candidate, skipping) { return nil }
            let candidatePath = "/" + candidate.joined(separator: "/")
            guard isLink(candidatePath) else {
                resolved = candidate
                continue
            }
            hops += 1
            guard hops <= maxHops, let target = readLink(candidatePath) else { return nil }
            if target.hasPrefix("/") { resolved = [] }
            remaining = target.split(separator: "/").map(String.init) + remaining
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// The real path of `url` without looking inside skipped folders, or nil when it leads into one.
    private func realPath(_ url: URL) -> String? {
        Self.resolveLinks(
            url.path(percentEncoded: false), skipping: skipping, isLink: Self.isLink, readLink: Self.readLink)
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
            if !skipping.isEmpty {
                // The folder itself may be a link into a skipped folder.
                guard let real = realPath(root), !Self.isInsideSystemApplications(path: real) else { continue }
            }
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
            // With folders to skip, links are resolved by hand and nothing under them is touched.
            var real: URL?
            if !skipping.isEmpty {
                guard let path = realPath(entry) else { continue }
                real = URL(filePath: path, directoryHint: .isDirectory)
            }
            if isApp {
                let resolved = real ?? entry.resolvingSymlinksInPath()
                if Self.isInsideSystemApplications(path: resolved.path(percentEncoded: false))
                    || (isLink && resolved.path.hasPrefix("/System/")) {
                    continue
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: (real ?? entry).path, isDirectory: &isDir), isDir.boolValue
                else { continue }
                guard seen.insert(entry.path).inserted else { continue }
                apps.append(makeApp(entry, linkTarget: isLink ? resolved : nil, metadataFrom: real))
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
        isInsideSystemApplications(path: url.resolvingSymlinksInPath().path)
    }

    /// For a path whose links are already resolved.
    private static func isInsideSystemApplications(path: String) -> Bool {
        path == "/System/Applications" || path.hasPrefix("/System/Applications/")
    }

    // MARK: - Metadata

    /// `linkTarget` is set when the `.app` entry is a symbolic link; metadata and size then come from
    /// the target (the link itself occupies next to nothing).
    /// `metadataFrom`: the hand-resolved real path to read Info.plist, the signature and the size
    /// from, so the kernel never follows the links again.
    private func makeApp(_ url: URL, linkTarget: URL?, metadataFrom real: URL? = nil) -> InstalledApp {
        let source = real ?? url
        let info = NSDictionary(contentsOf: source.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
        func string(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        let executable = string("CFBundleExecutable")
        let lastUsed = try? source.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
        return InstalledApp(
            url: url,
            displayName: string("CFBundleDisplayName") ?? string("CFBundleName") ?? fileName,
            bundleID: string("CFBundleIdentifier"),
            teamID: teamIdentifier(of: source),
            executableName: executable,
            steamAppID: executable.flatMap { steamAppID(in: source.appending(path: "Contents/MacOS/\($0)")) },
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
