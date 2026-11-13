import Foundation

public enum JunkCatalog {
    /// What `dustling-cli clean` cleans from `scans`, in their order: every category selected by
    /// default (`isSelectedByDefault`), plus the ones named in `including` (`--include <id>`). Never
    /// the Trash, which is only ever emptied as a whole, and never a category Dustling leaves alone
    /// (`isNeverCleaned`), even when named.
    public static func cleanChoice(_ scans: [CategoryScan], including: [JunkCategoryID]) -> [CategoryScan] {
        scans.filter { scan in
            scan.category.id != .trash && !scan.category.isNeverCleaned
                && (scan.category.isSelectedByDefault || including.contains(scan.category.id))
        }
    }

    /// Why a category Dustling leaves alone is never cleaned, for the CLI.
    public static let neverCleanedNote = "macOS manages these, so Dustling leaves them alone."

    /// Logical size at or above which a Downloads item counts as large (500 MB).
    public static let largeDownloadThreshold: UInt64 = 500 * 1024 * 1024
    /// Items in Downloads not accessed for longer than this count as old (90 days).
    public static let oldDownloadAge: TimeInterval = 90 * 24 * 60 * 60

    /// Browser cache folder names in `~/Library/Caches` and the bundle ID of the app that owns each.
    static let browserCacheOwners: [String: String] = [
        "Google": "com.google.Chrome",
        "Firefox": "org.mozilla.firefox",
        "BraveSoftware": "com.brave.Browser",
        "Microsoft Edge": "com.microsoft.edgemac",
        "com.apple.Safari": "com.apple.Safari",
        "company.thebrowser.Browser": "company.thebrowser.Browser",
    ]
    static let browserCacheNames = Set(browserCacheOwners.keys)

    /// The bundle ID of the app an item most likely belongs to, for "is it open right now" checks:
    /// a container cache (`Containers/<id>/Data/Library/Caches/*`) belongs to `<id>`, a known browser
    /// cache folder to its browser, anything else to the bundle ID its name spells.
    public static func ownerBundleID(of item: URL) -> String {
        let parent = item.deletingLastPathComponent().standardizedFileURL.pathComponents
        if parent.count >= 5, Array(parent.suffix(3)) == ["Data", "Library", "Caches"],
           parent[parent.count - 5] == "Containers" {
            return parent[parent.count - 4]
        }
        let name = item.lastPathComponent
        return browserCacheOwners[name] ?? name
    }
    static let packageManagerCacheNames: Set<String> = ["Homebrew", "pip", "CocoaPods", "Yarn"]
    private static let ignoredDownloadNames: Set<String> = [".DS_Store", ".localized"]

    /// Categories in claim order: an item belongs to the first category that claims it.
    /// `textualUnder`: folders whose exclusions are keyed by text only (consent folders without Full
    /// Disk Access), so building the catalog never looks inside them.
    public static func standard(
        _ env: SystemEnvironment, now: Date = .now, options: ScanOptions = ScanOptions(), textualUnder: [URL] = []
    ) -> [JunkCategory] {
        applying(options, to: base(env, now: now, includeExternalTrash: options.includeExternalTrash),
                 environment: env, now: now, textualUnder: textualUnder)
    }

    /// Wraps every category's filter so excluded items (inside an exclusion, or containing one) and,
    /// when asked, recently changed items never reach measuring. The Trash category is left untouched
    /// (no exclusions, no recency): exclusions guard what would be MOVED to the Trash, and the Trash is
    /// only ever emptied as a whole, so its list must match what Empty Trash deletes.
    private static func applying(
        _ options: ScanOptions, to categories: [JunkCategory], environment: SystemEnvironment, now: Date,
        textualUnder: [URL]
    ) -> [JunkCategory] {
        let guardPaths = options.protectedPaths(environment: environment, textualUnder: textualUnder)
        let days = (options.skipChangedWithinDays ?? 0) > 0 ? options.skipChangedWithinDays : nil
        guard days != nil || !options.exclusions.isEmpty else { return categories }
        return categories.map { category in
            let inner = category.itemFilter
            if category.id == .trash { return category }
            return JunkCategory(
                id: category.id, title: category.title, selection: category.selection,
                requiresAdmin: category.requiresAdmin, roots: category.roots, expansions: category.expansions,
                itemFilter: { url in
                    guard inner(url), guardPaths.exclusionReason(for: url) == nil else { return false }
                    if let days, changedWithin(days: days, url, now: now) { return false }
                    return true
                },
                measuredFilter: category.measuredFilter)
        }
    }

    /// True when the item's own modification date is less than `days` days before `now` (or in the
    /// future). Unreadable attributes count as not recent: the item then goes on to be measured, which
    /// reports it if it really can't be read.
    private static func changedWithin(days: Int, _ url: URL, now: Date) -> Bool {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return false }
        let modified = Date(timeIntervalSince1970:
            TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return now.timeIntervalSince(modified) < TimeInterval(days) * 24 * 60 * 60
    }

    private static func base(_ env: SystemEnvironment, now: Date, includeExternalTrash: Bool) -> [JunkCategory] {
        let lib = env.userLibrary
        let caches = lib.appending(path: "Caches")
        let downloads = env.home.appending(path: "Downloads")

        return [
            JunkCategory(
                id: .browserCaches, title: "Browser caches", selection: .preselected, requiresAdmin: false,
                roots: [caches], itemFilter: { browserCacheNames.contains($0.lastPathComponent) }),
            JunkCategory(
                id: .xcodeJunk, title: "Xcode build data", selection: .preselected,
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
                roots: [caches],
                expansions: [RootExpansion(parent: lib.appending(path: "Containers"), subpath: "Data/Library/Caches")]),
            JunkCategory(
                id: .userLogs, title: "App logs", selection: .preselected, requiresAdmin: false,
                roots: [lib.appending(path: "Logs")], itemFilter: { $0.lastPathComponent != "Dustling" }),
            JunkCategory(
                id: .systemCachesAndLogs, title: "System caches and logs", selection: .preselected,
                requiresAdmin: true,
                roots: env.systemManagedFolders),
            JunkCategory(
                id: .trash, title: "Trash", selection: .emptyTrashOnly, requiresAdmin: false,
                roots: [env.userTrash],
                expansions: includeExternalTrash
                    ? [RootExpansion(parent: env.volumesDirectory, subpath: ".Trashes/\(env.userID)")] : []),
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
                itemFilter: { !ignoredDownloadNames.contains($0.lastPathComponent) },
                measuredFilter: { url, size in try isLargeOrOldDownload(url, size: size, now: now) }),
            JunkCategory(
                id: .mailDownloads, title: "Mail downloads", selection: .review, requiresAdmin: false,
                roots: [lib.appending(path: "Containers/com.apple.mail/Data/Library/Mail Downloads")]),
        ]
    }

    /// Files use logical size (so sparse files qualify, R3); directories use the allocated bytes already
    /// measured (R8). Throws if the attributes cannot be read.
    private static func isLargeOrOldDownload(_ url: URL, size: SizeResult, now: Date) throws -> Bool {
        let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .isDirectoryKey])
        if let accessed = v.contentAccessDate, now.timeIntervalSince(accessed) > oldDownloadAge { return true }
        if v.isDirectory == true { return size.bytes >= largeDownloadThreshold }
        return UInt64(v.fileSize ?? 0) >= largeDownloadThreshold
    }
}
