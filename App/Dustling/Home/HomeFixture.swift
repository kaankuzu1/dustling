#if DEBUG
import DustlingAppModel
import DustlingCore
import Foundation

/// DEBUG only. `-DustlingHomeFixture ready|scanning|moving|done|limited|emptytrash|emptytrashproblems|reviewfiles|closeapps` shows Home and the Junk scan with
/// the approved mockup's sample numbers (`DISK`, `CATS` and `TRASH` in screens.html), for screenshots
/// without anyone's real files:
/// - Full Disk Access reads as on (`limited`: off, with the consent places locked), in memory only.
/// - The disk, the places check, the scan results and the Trash are samples. Nothing is read from
///   disk for them, and the junk and Trash models refuse to scan, clean, put back or empty anything.
/// - `loading`: the disk and the places check never answer, so Home (and the onboarding's place
///   count) stay in their loading skeletons. `loadingscan`: the disk is read but the scan has
///   finished no place yet, so Home shows the hero with the scan's skeletons.
/// - `done` shows the summary of a sample cleanup that was never run.
/// - `moving` shows a cleanup of the selected tiles part way through (it never moves anything).
/// - `closeapps` is `ready` with the "Close apps to include their files?" sheet for two sample apps
///   (its buttons do nothing).
/// - `emptytrash` and `reviewfiles` are `ready` with the Junk scan's Empty Trash or Review files sheet
///   open (the sheets list the sample items; Empty Trash refuses to delete anything). `reviewfiles`
///   also ticks System caches and logs, so its "Needs your Mac password" note shows.
///
/// Combine with `-DustlingUninstallerFixture list` and `-DustlingStartupFixture normal` for Home's
/// tool cards; Home stays selected.
enum HomeFixture {
    static let argument = "DustlingHomeFixture"

    /// The fixture state from the launch arguments, nil when it is off.
    static var state: String? { UserDefaults.standard.string(forKey: argument) }

    static var isLimited: Bool { state == "limited" }

    /// `loading`: the disk and the places check never answer.
    static var neverAnswers: Bool { state == "loading" }

    /// Blocks the calling (background) thread for good: a read that never finishes.
    static func waitForever<T>() -> T {
        while true { Thread.sleep(forTimeInterval: 3_600) }
    }

    private static let gb: Double = 1_000_000_000

    /// The mockup's disk: 494.38 GB, 9.8 GB available, next to nothing purgeable.
    static let storage = StorageInfo(
        totalBytes: 494_380_000_000, availableForImportantUsage: 9_800_000_000,
        availableBytes: 9_700_000_000, localSnapshotCount: 0)

    /// Every place open, or (limited) the consent places locked as without Full Disk Access.
    static func places(limited: Bool) -> [Place] {
        let locked: Set<JunkCategoryID> = [.oldInstallers, .largeOldDownloads, .mailDownloads, .iosBackups, .trash]
        return JunkCategoryID.allCases.map { id in
            if limited && locked.contains(id) { return Place(id: id, access: .locked) }
            if limited && id == .userCaches { return Place(id: id, access: .readable, lockedExpansions: true) }
            return Place(id: id, access: .readable)
        }
    }

    /// The scan results, one sample item list per category. The items sit under the real home folder
    /// (so the screen shortens them to `~`) but don't exist: nothing ever reads or moves them.
    static func scans(catalog: [JunkCategory], home: URL) -> [CategoryScan] {
        let lib = home.appending(path: "Library")
        func items(_ list: [(String, Double)], owner: String? = nil, inUse: Bool = false) -> [(URL, UInt64, String?, Bool)] {
            list.map { (lib.appending(path: $0.0), UInt64($0.1 * gb), owner, inUse) }
        }
        let byID: [JunkCategoryID: [(URL, UInt64, String?, Bool)]] = [
            .xcodeJunk: items([
                ("Developer/CoreSimulator/Caches/iOS_21E213", 6.02),
                ("Developer/Xcode/DerivedData/Dustling-gbhyqz", 3.41),
                ("Developer/Xcode/DerivedData/paclike-akdjeu", 2.88),
                ("Developer/CoreSimulator/Caches/watchOS_21R355", 1.94),
                ("Developer/Xcode/DerivedData/klipai-dhwoxq", 0.42),
                ("Developer/Xcode/DerivedData/ModuleCache.noindex", 0.25),
            ]),
            .systemCachesAndLogs: [
                (URL(filePath: "/Library/Caches/com.apple.iconservices.store"), UInt64(3.9 * gb), nil, false),
                (URL(filePath: "/Library/Logs/DiagnosticReports"), UInt64(2.51 * gb), nil, false),
            ],
            .userCaches: items([
                ("Caches/com.spotify.client", 1.62), ("Caches/com.figma.Desktop", 1.21),
                ("Caches/com.microsoft.teams2", 0.87), ("Caches/com.tinyspeck.slackmacgap", 0.48),
            ]),
            .packageManagerCaches: items([("Caches/Homebrew", 1.41), ("Caches/pip", 0.16)])
                + [(home.appending(path: ".npm/_cacache/content-v2"), UInt64(0.49 * gb), nil, false)],
            .browserCaches: items([("Caches/Google", 0.92), ("Caches/Arc", 0.36)])
                + items([("Caches/com.apple.Safari", 0.56)], owner: "com.apple.Safari", inUse: true),
            .userLogs: items([("Logs/DiagnosticReports", 0.81), ("Logs/JetBrains", 0.26)]),
            .iosBackups: items([
                ("Application Support/MobileSync/Backup/00008110-001A", 4.6),
                ("Application Support/MobileSync/Backup/00008030-0042", 4.3),
            ]),
            .oldInstallers: [
                (home.appending(path: "Downloads/Docker.dmg"), UInt64(1.42 * gb), nil, false),
                (home.appending(path: "Downloads/Xcode_15.3.xip.pkg"), UInt64(1.21 * gb), nil, false),
                (home.appending(path: "Downloads/Figma.dmg"), UInt64(0.49 * gb), nil, false),
            ],
            .xcodeArchives: items([("Developer/Xcode/Archives/2024-03-11", 0.74)]),
            .largeOldDownloads: [
                (home.appending(path: "Downloads/conference-talk.mov"), UInt64(2.2 * gb), nil, false),
            ],
            .mailDownloads: items([("Containers/com.apple.mail/Data/Library/Mail Downloads/A1F2", 0.61)]),
        ]
        return catalog.compactMap { category in
            guard category.id != .trash else { return nil }
            let list = (byID[category.id] ?? []).map { url, bytes, owner, inUse in
                JunkItem(
                    url: url, bytes: bytes, category: category.id,
                    inUseByBundleID: inUse ? owner : nil, ownerBundleID: owner ?? JunkCatalog.ownerBundleID(of: url))
            }
            return CategoryScan(
                category: category, items: list, bytes: list.reduce(0) { $0 + $1.bytes }, issues: [], stopped: false)
        }
    }

    /// The mockup's Trash: 3.27 GB in a few items.
    /// Two apps holding selected junk, for the Close apps sheet. Apple's own apps, so the icons are
    /// nobody's personal apps.
    static let closeAppsHolders = [
        OpenAppHolder(bundleID: "com.apple.Music", name: "Music", bundleURL: URL(filePath: "/System/Applications/Music.app"),
                      bytes: UInt64(1.84 * gb), itemCount: 3),
        OpenAppHolder(bundleID: "com.apple.mail", name: "Mail", bundleURL: URL(filePath: "/System/Applications/Mail.app"),
                      bytes: UInt64(0.62 * gb), itemCount: 2),
    ]

    /// A finished Empty Trash that left five installer-owned apps and one protected item behind.
    /// Never run: the paths are the fixture's.
    static func emptyTrashProblemRecord() -> RunRecord {
        var entries = [JournalEntry(originalPath: "/sample/Screen Recording.mov", bytes: UInt64(1.9 * gb), outcome: .deleted),
                       JournalEntry(originalPath: "/sample/old-project.zip", bytes: UInt64(0.82 * gb), outcome: .deleted)]
        entries += (1...5).map { JournalEntry(originalPath: "/sample/TI App \($0)", bytes: 0, outcome: .needsAdmin) }
        entries.append(JournalEntry(originalPath: "/sample/Protected", bytes: 0, outcome: .failed(reason: "protected by macOS")))
        return RunRecord(startedAt: Date(), kind: .emptyTrash, entries: entries, restorable: false)
    }

    static func trashItems(home: URL) -> [TrashItem] {
        let trash = home.appending(path: ".Trash")
        return [
            ("Screen Recording 2024-03-02.mov", 1.9, 1), ("old-project.zip", 0.82, 1),
            ("Untitled.dmg", 0.38, 1), ("Photos export", 0.17, 38),
        ].map { name, size, files in
            TrashItem(url: trash.appending(path: name), size: SizeResult(bytes: UInt64(size * gb), fileCount: files))
        }
    }

    /// A finished cleanup of the selected categories: everything moved except Safari's cache, which
    /// is in use. Never run: the paths are the fixture's.
    static func cleanup(of scans: [CategoryScan]) -> RunRecord {
        var entries: [JournalEntry] = []
        for scan in scans where scan.category.selection == .preselected && !scan.category.requiresAdmin {
            for item in scan.items {
                let path = item.url.path(percentEncoded: false)
                let outcome: DeletionOutcome = item.inUseByBundleID.map { .skipped(reason: "in use by \($0)") }
                    ?? .movedToTrash(trashedPath: "/sample")
                entries.append(JournalEntry(originalPath: path, bytes: item.bytes, outcome: outcome))
            }
        }
        return RunRecord(startedAt: .now.addingTimeInterval(-120), kind: .junkClean, entries: entries, restorable: true)
    }

    /// The scanning state: three of the places done, the counter part way.
    static func scanningProgress(home: URL, total: Int) -> ScanProgress {
        ScanProgress(
            currentPath: home.appending(path: "Library/Caches/com.spotify.client/Data/index"),
            bytesFound: UInt64(19.4 * gb), categoriesDone: 3, categoriesTotal: total)
    }

    /// `loadingscan`: the scan has only just started.
    static func startingProgress(home: URL, total: Int) -> ScanProgress {
        ScanProgress(
            currentPath: home.appending(path: "Library/Caches"), bytesFound: 0, categoriesDone: 0,
            categoriesTotal: total)
    }
}
#endif
