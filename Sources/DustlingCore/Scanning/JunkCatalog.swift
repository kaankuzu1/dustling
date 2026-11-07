import Foundation

public enum JunkCatalog {
    /// Logical size at or above which a Downloads item counts as large (500 MB).
    public static let largeDownloadThreshold: UInt64 = 500 * 1024 * 1024
    /// Items in Downloads not accessed for longer than this count as old (90 days).
    public static let oldDownloadAge: TimeInterval = 90 * 24 * 60 * 60

    static let browserCacheNames: Set<String> = [
        "com.apple.Safari", "Google", "Firefox", "BraveSoftware", "Microsoft Edge", "company.thebrowser.Browser",
    ]
    static let packageManagerCacheNames: Set<String> = ["Homebrew", "pip", "CocoaPods", "Yarn"]
    private static let ignoredDownloadNames: Set<String> = [".DS_Store", ".localized"]

    /// Categories in claim order: an item belongs to the first category that claims it.
    public static func standard(_ env: SystemEnvironment, now: Date = .now) -> [JunkCategory] {
        let lib = env.userLibrary
        let caches = lib.appending(path: "Caches")
        let downloads = env.home.appending(path: "Downloads")

        return [
            JunkCategory(
                id: .browserCaches, title: "Browser caches", selection: .preselected, requiresAdmin: false,
                roots: [caches], itemFilter: { browserCacheNames.contains($0.lastPathComponent) }),
            JunkCategory(
                id: .xcodeJunk, title: "Xcode derived data and simulator caches", selection: .preselected,
                requiresAdmin: false,
                roots: [
                    lib.appending(path: "Developer/Xcode/DerivedData"),
                    lib.appending(path: "Developer/CoreSimulator/Caches"),
                ]),
            JunkCategory(
                id: .packageManagerCaches, title: "Package manager caches", selection: .preselected,
                requiresAdmin: false,
                roots: [caches, env.home.appending(path: ".npm/_cacache")],
                itemFilter: { url in
                    // Children of ~/.npm/_cacache are all fair game; ~/Library/Caches is name-filtered.
                    url.deletingLastPathComponent().lastPathComponent == "_cacache"
                        || packageManagerCacheNames.contains(url.lastPathComponent)
                }),
            JunkCategory(
                id: .userCaches, title: "App caches", selection: .preselected, requiresAdmin: false,
                roots: [caches] + containerCaches(in: lib)),
            JunkCategory(
                id: .userLogs, title: "App logs", selection: .preselected, requiresAdmin: false,
                roots: [lib.appending(path: "Logs")], itemFilter: { $0.lastPathComponent != "Dustling" }),
            JunkCategory(
                id: .systemCachesAndLogs, title: "System caches and logs", selection: .preselected,
                requiresAdmin: true,
                roots: [env.systemLibrary.appending(path: "Caches"), env.systemLibrary.appending(path: "Logs")]),
            JunkCategory(
                id: .trash, title: "Trash", selection: .emptyTrashOnly, requiresAdmin: false,
                roots: trashRoots(env)),
            JunkCategory(
                id: .oldInstallers, title: "Old installers", selection: .review, requiresAdmin: false,
                roots: [downloads],
                itemFilter: { ["dmg", "pkg"].contains($0.pathExtension.lowercased()) }),
            JunkCategory(
                id: .iosBackups, title: "iPhone and iPad backups", selection: .review, requiresAdmin: false,
                roots: [lib.appending(path: "Application Support/MobileSync/Backup")]),
            JunkCategory(
                id: .xcodeArchives, title: "Xcode archives", selection: .review, requiresAdmin: false,
                roots: [lib.appending(path: "Developer/Xcode/Archives")]),
            JunkCategory(
                id: .largeOldDownloads, title: "Large and old downloads", selection: .review,
                requiresAdmin: false, roots: [downloads],
                itemFilter: { isLargeOrOldDownload($0, now: now) }),
            JunkCategory(
                id: .mailDownloads, title: "Mail downloads", selection: .review, requiresAdmin: false,
                roots: [lib.appending(path: "Containers/com.apple.mail/Data/Library/Mail Downloads")]),
        ]
    }

    private static func containerCaches(in library: URL) -> [URL] {
        let containers = library.appending(path: "Containers")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: containers, includingPropertiesForKeys: nil)) ?? []
        return entries
            .map { $0.appending(path: "Data/Library/Caches") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private static func trashRoots(_ env: SystemEnvironment) -> [URL] {
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: env.volumesDirectory, includingPropertiesForKeys: nil)) ?? []
        let perVolume = volumes
            .sorted { $0.path < $1.path }
            .map { $0.appending(path: ".Trashes/\(env.userID)") }
        return [env.userTrash] + perVolume
    }

    /// Files use logical size (so sparse files qualify) and `contentAccessDate`; directories use their
    /// allocated size.
    private static func isLargeOrOldDownload(_ url: URL, now: Date) -> Bool {
        if ignoredDownloadNames.contains(url.lastPathComponent) { return false }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return false }
        if let accessed = v.contentAccessDate, now.timeIntervalSince(accessed) > oldDownloadAge { return true }
        if v.isDirectory == true {
            return DirectorySizer().measure(url).bytes >= largeDownloadThreshold
        }
        return UInt64(v.fileSize ?? 0) >= largeDownloadThreshold
    }
}
