import DustlingCore
import Foundation
import Observation

/// Whether Dustling can open one place it scans (one junk category).
public enum PlaceAccess: Equatable, Sendable {
    /// Every root opens, or doesn't exist (nothing to scan there).
    case readable
    /// At least one root refuses with EPERM or EACCES while Full Disk Access is off: macOS protects
    /// it, and Full Disk Access opens it.
    case locked
    /// At least one root can't be opened for a reason Full Disk Access doesn't fix: a permission
    /// refusal while access is already on, or any other error (EIO, ELOOP, EMFILE…). Never counted
    /// as needing Full Disk Access.
    case unreadable
}

public struct Place: Equatable, Sendable, Identifiable {
    public let id: JunkCategoryID
    public let access: PlaceAccess

    public init(id: JunkCategoryID, access: PlaceAccess) {
        self.id = id
        self.access = access
    }

    /// How the place reads inside a sentence, e.g. "Dustling can't see Xcode data or the Trash".
    public var nameInSentence: String { Self.nameInSentence(id) }

    public static func nameInSentence(_ id: JunkCategoryID) -> String {
        switch id {
        case .browserCaches: "browser caches"
        case .xcodeJunk: "Xcode data"
        case .packageManagerCaches: "package manager caches"
        case .userCaches: "app caches"
        case .userLogs: "app logs"
        case .systemCachesAndLogs: "system caches"
        case .trash: "the Trash"
        case .oldInstallers: "old installers"
        case .iosBackups: "iPhone and iPad backups"
        case .xcodeArchives: "Xcode archives"
        case .largeOldDownloads: "large and old downloads"
        case .mailDownloads: "Mail downloads"
        }
    }
}

/// Checks each junk category's roots the way the scanner opens them, without measuring anything.
public enum PlaceAccessChecker {
    public enum PathAccess: Equatable, Sendable {
        case ok, missing, denied
        /// Any other `opendir` failure, with its errno.
        case other(Int32)
    }

    /// One `Place` per category, in catalog order. A root that is missing doesn't lock a place (there
    /// is nothing there to scan). For expanded roots (`Containers/*/Data/Library/Caches`) only the
    /// parent is opened: opening other apps' containers one by one can trigger a consent prompt.
    ///
    /// Roots inside `consentFolders` (Downloads, Desktop, Documents, other apps' containers) are never opened without Full Disk
    /// Access: macOS would show a consent prompt and block until it is answered. Without Full Disk
    /// Access they count as locked, which is what they are until the user allows them.
    ///
    /// A refusal only means "needs Full Disk Access" while access is off. With access on it, and any
    /// other error, make the place `.unreadable`; other errors are logged.
    public static func check(
        _ categories: [JunkCategory], consentFolders: [URL] = [], fullDiskAccessGranted: Bool = false,
        probe: (URL) -> PathAccess = PlaceAccessChecker.probe
    ) -> [Place] {
        let consent = consentFolders.map(components)
        func access(_ url: URL) -> PathAccess {
            let path = components(url)
            let asksConsent = consent.contains { path.count >= $0.count && Array(path.prefix($0.count)) == $0 }
            if asksConsent && !fullDiskAccessGranted { return .denied }
            return probe(url)
        }
        return categories.map { category in
            var result = PlaceAccess.readable
            for url in category.roots + category.expansions.map(\.parent) {
                switch access(url) {
                case .ok, .missing:
                    continue
                case .denied where !fullDiskAccessGranted:
                    result = .locked
                case .denied:
                    NSLog("Dustling: can't open \(url.path(percentEncoded: false)) although Full Disk Access is on")
                    if result != .locked { result = .unreadable }
                case .other(let code):
                    NSLog("Dustling: can't open \(url.path(percentEncoded: false)): \(String(cString: strerror(code)))")
                    if result != .locked { result = .unreadable }
                }
            }
            return Place(id: category.id, access: result)
        }
    }

    /// The folders macOS guards with their own consent prompt, for `check`: Downloads, Desktop and
    /// Documents, and other apps' containers ("would like to access data from other apps").
    public static func consentFolders(_ environment: SystemEnvironment) -> [URL] {
        ["Downloads", "Desktop", "Documents"].map { environment.home.appending(path: $0) }
            + [environment.userLibrary.appending(path: "Containers")]
    }

    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.path(percentEncoded: false).split(separator: "/").map(String.init)
    }

    /// Opens `url` as a directory and closes it at once, like the scanner's listing. Contents are
    /// never read.
    public static func probe(_ url: URL) -> PathAccess {
        guard let dir = opendir(url.path(percentEncoded: false)) else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case EPERM, EACCES: return .denied
            case let code: return .other(code)
            }
        }
        closedir(dir)
        return .ok
    }
}

/// Which places Dustling can see right now, for onboarding ("Dustling can see N of 12 places") and
/// the limited-mode banner on Home. `places` is nil until the first check finishes.
@MainActor @Observable
public final class PlacesModel {
    public private(set) var places: [Place]?

    @ObservationIgnored private let check: @Sendable (_ fullDiskAccessGranted: Bool) -> [Place]
    /// Bumped per refresh; only the newest refresh publishes.
    @ObservationIgnored private var generation = 0

    public init(check: @escaping @Sendable (_ fullDiskAccessGranted: Bool) -> [Place]) {
        self.check = check
    }

    public convenience init(environment: SystemEnvironment) {
        self.init(check: { granted in
            PlaceAccessChecker.check(
                JunkCatalog.standard(environment),
                consentFolders: PlaceAccessChecker.consentFolders(environment),
                fullDiskAccessGranted: granted)
        })
    }

    public var total: Int { places?.count ?? 0 }
    public var readableCount: Int { places?.filter { $0.access == .readable }.count ?? 0 }
    /// Places that need Full Disk Access. Empty whenever access is on.
    public var lockedPlaces: [Place] { places?.filter { $0.access == .locked } ?? [] }
    /// Places Dustling can't read for another reason.
    public var unreadablePlaces: [Place] { places?.filter { $0.access == .unreadable } ?? [] }

    /// "Dustling can't read the folders for app logs or the Trash." nil when every place opens.
    public var unreadableSentence: String? { Self.unreadableSentence(unreadablePlaces, limit: 3) }

    public nonisolated static func unreadableSentence(_ places: [Place], limit: Int) -> String? {
        let names = places.prefix(max(1, limit)).map(\.nameInSentence)
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
        return "Dustling can't read the \(places.count == 1 ? "folder" : "folders") for \(list)."
    }

    /// "Without it, Dustling can't see Xcode data, system caches or Mail downloads." Names at most
    /// `limit` places, in catalog order. nil when nothing is locked.
    public var lockedSentence: String? { Self.lockedSentence(lockedPlaces, limit: 3) }

    public nonisolated static func lockedSentence(_ locked: [Place], limit: Int) -> String? {
        let names = locked.prefix(max(1, limit)).map(\.nameInSentence)
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
        return "Without it, Dustling can't see \(list)."
    }

    /// Re-checks every place off the main actor. Pass whether Full Disk Access is on: without it,
    /// folders that would prompt for consent aren't opened.
    public func refresh(fullDiskAccessGranted: Bool) async {
        let check = self.check
        generation += 1
        let mine = generation
        let result = await Blocking.run { check(fullDiskAccessGranted) }
        guard mine == generation else { return }
        places = result
    }
}
