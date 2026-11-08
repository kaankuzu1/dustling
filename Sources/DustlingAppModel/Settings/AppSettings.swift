import DustlingCore
import Foundation
import Observation

/// Light, dark or whatever macOS uses (Settings > General > Appearance).
public enum AppearanceSetting: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: Self { self }

    public var title: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// What macOS says about Dustling as a login item (`SMAppService.Status`, minus the framework).
public enum LoginItemStatus: Equatable, Sendable {
    case enabled, notRegistered, requiresApproval, notFound
}

/// Registers Dustling to open at login. The app passes `SMAppService.mainApp`; tests pass a fake, so
/// running the tests never adds a login item to the Mac.
public protocol LoginItemService: Sendable {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
}

/// One excluded folder as Settings lists it.
public struct ExclusionRow: Identifiable, Equatable, Sendable {
    /// The saved entry, exactly as stored. Unique in the list.
    public let id: String
    /// The path with the home folder shown as `~`.
    public let display: String
    /// Why the entry is ignored, in plain words, or nil when it is in effect.
    public let problem: String?
}

/// Every setting in the Settings window, saved in `UserDefaults`.
///
/// The scan settings are one `ScanOptions` value (Task 4), saved as JSON, so what is scanned and what
/// may be moved can never disagree. `onScanOptionsChanged` tells the app after every change, so new
/// exclusions protect folders right away, without a relaunch.
@MainActor @Observable
public final class AppSettings {
    public static let scanOptionsKey = "scanOptions"
    public static let appearanceKey = "appearance"
    public static let preselectSafeKey = "preselectSafeCategories"
    public static let showReviewItemsKey = "showReviewItems"
    public static let browserCachesKey = "includeBrowserCaches"

    /// A fresh install skips items changed in the last 7 days, as the approved Settings show.
    public static let defaultScanOptions = ScanOptions(skipChangedWithinDays: 7)
    /// The choices for "Skip files changed in the last". nil is Off.
    public static let skipDayChoices: [Int?] = [nil, 1, 3, 7, 14, 30]
    /// The locked chips under Exclusions (SCREENS-final §7, P05).
    public static let alwaysProtected = [
        "Documents", "Desktop", "Pictures", "Music", "Movies", "iCloud Drive", "/System", "Other users",
    ]

    public private(set) var scanOptions: ScanOptions
    /// Set when the saved scan settings couldn't be read and the defaults are in use instead.
    public private(set) var loadProblem: String?

    public var appearance: AppearanceSetting {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }
    public var preselectSafe: Bool {
        didSet { defaults.set(preselectSafe, forKey: Self.preselectSafeKey) }
    }
    public var showReviewItems: Bool {
        didSet { defaults.set(showReviewItems, forKey: Self.showReviewItemsKey) }
    }
    public var includeBrowserCaches: Bool {
        didSet { defaults.set(includeBrowserCaches, forKey: Self.browserCachesKey) }
    }
    /// Empty Trash is the only permanent step, so its confirmation can't be turned off.
    public let alwaysConfirmEmptyTrash = true

    /// On when Dustling is registered (or waiting for approval) as a login item.
    public private(set) var openAtLogin = false
    /// A plain sentence when opening at login needs the user or didn't work.
    public private(set) var loginItemNote: String?
    public private(set) var loginItemNeedsApproval = false

    @ObservationIgnored public var onScanOptionsChanged: ((ScanOptions) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: SystemEnvironment
    @ObservationIgnored private let loginItems: LoginItemService

    public init(defaults: UserDefaults = .standard, environment: SystemEnvironment, loginItems: LoginItemService) {
        self.defaults = defaults
        self.environment = environment
        self.loginItems = loginItems
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(AppearanceSetting.init(rawValue:)) ?? .system
        preselectSafe = defaults.object(forKey: Self.preselectSafeKey) as? Bool ?? true
        showReviewItems = defaults.object(forKey: Self.showReviewItemsKey) as? Bool ?? true
        includeBrowserCaches = defaults.object(forKey: Self.browserCachesKey) as? Bool ?? true
        if let data = defaults.data(forKey: Self.scanOptionsKey) {
            if let saved = try? JSONDecoder().decode(ScanOptions.self, from: data) {
                scanOptions = saved
            } else {
                scanOptions = Self.defaultScanOptions
                loadProblem = "Your scan settings couldn't be read, so Dustling went back to the defaults."
            }
        } else if defaults.object(forKey: Self.scanOptionsKey) != nil {
            scanOptions = Self.defaultScanOptions
            loadProblem = "Your scan settings couldn't be read, so Dustling went back to the defaults."
        } else {
            scanOptions = Self.defaultScanOptions
        }
        refreshLoginItem()
    }

    // MARK: Scanning

    public var skipChangedWithinDays: Int? {
        get { scanOptions.skipChangedWithinDays }
        set { update { $0.skipChangedWithinDays = newValue } }
    }

    public var includeExternalTrash: Bool {
        get { scanOptions.includeExternalTrash }
        set { update { $0.includeExternalTrash = newValue } }
    }

    /// Whether the junk scan covers this category with the current toggles.
    public func scans(_ id: JunkCategoryID, selection: Selection) -> Bool {
        if id == .browserCaches, !includeBrowserCaches { return false }
        if selection == .review, !showReviewItems { return false }
        return true
    }

    /// "7 days", "1 day" or "Off".
    public static func skipTitle(_ days: Int?) -> String {
        guard let days else { return "Off" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    // MARK: Exclusions

    public var exclusionRows: [ExclusionRow] {
        var seen = Set<String>()
        return scanOptions.exclusions.compactMap { entry in
            guard seen.insert(entry).inserted else { return nil }
            let normalized = ScanOptions.normalizeExclusions([entry], home: environment.home)
            let problem = normalized.ignored.first.map { "Ignored: \($0.reason)" }
            let shown = normalized.accepted.first.map { Self.tilde($0.path(percentEncoded: false), home: environment.home) }
            return ExclusionRow(id: entry, display: shown ?? entry, problem: problem)
        }
    }

    /// Adds a folder picked in the open panel. Returns why it wasn't added, or nil when it was.
    @discardableResult
    public func addExclusion(_ url: URL) -> String? {
        guard let folder = ScanOptions.normalizeExclusions([url.path(percentEncoded: false)], home: environment.home)
            .accepted.first else { return "Dustling can't use that folder." }
        let path = folder.path(percentEncoded: false)
        let existing = scanOptions.exclusionURLs(home: environment.home).map { $0.path(percentEncoded: false) }
        if existing.contains(path) { return "That folder is already excluded." }
        let guardOnly = ProtectedPaths(environment: environment)
        if case .denied = guardOnly.verdict(for: folder, allowedRoots: [URL(filePath: "/")]) {
            return "Dustling never touches \(folder.lastPathComponent) anyway, so it doesn't need excluding."
        }
        update { $0.exclusions.append(path) }
        return nil
    }

    public func removeExclusion(_ row: ExclusionRow) {
        update { $0.exclusions.removeAll { $0 == row.id } }
    }

    // MARK: Open at login

    public func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try loginItems.register() } else { try loginItems.unregister() }
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            loginItemNote = "Dustling couldn't turn this \(on ? "on" : "off"). \(error.localizedDescription)"
        }
    }

    /// Re-reads the login item status (the user may have changed it in System Settings).
    public func refreshLoginItem() {
        let status = loginItems.status()
        openAtLogin = status == .enabled || status == .requiresApproval
        loginItemNeedsApproval = status == .requiresApproval
        loginItemNote = status == .requiresApproval
            ? "macOS needs your OK. Turn on Dustling in System Settings > General > Login Items."
            : nil
    }

    // MARK: Private

    private func update(_ change: (inout ScanOptions) -> Void) {
        var options = scanOptions
        change(&options)
        scanOptions = options
        if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: Self.scanOptionsKey)
            loadProblem = nil
        }
        onScanOptionsChanged?(options)
    }

    nonisolated static func tilde(_ path: String, home: URL) -> String {
        let homePath = home.path(percentEncoded: false).hasSuffix("/")
            ? String(home.path(percentEncoded: false).dropLast()) : home.path(percentEncoded: false)
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
