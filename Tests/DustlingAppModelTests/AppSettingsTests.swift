import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// A login item service that records calls instead of touching macOS.
final class FakeLoginItems: LoginItemService, @unchecked Sendable {
    var current: LoginItemStatus
    var registerError: Error?
    private(set) var calls: [String] = []

    init(_ status: LoginItemStatus = .notRegistered) { current = status }

    func status() -> LoginItemStatus { current }

    func register() throws {
        calls.append("register")
        if let registerError { throw registerError }
        current = .enabled
    }

    func unregister() throws {
        calls.append("unregister")
        current = .notRegistered
    }
}

@MainActor
struct AppSettingsTests {
    private struct Boom: LocalizedError { var errorDescription: String? { "The operation couldn't be completed." } }

    private func fresh() -> UserDefaults {
        let name = "dustling-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let environment = SystemEnvironment(
        home: URL(filePath: "/Users/tester"), applicationDirectories: [], systemLibrary: URL(filePath: "/Library"),
        volumesDirectory: URL(filePath: "/Volumes"), userID: 501)

    @Test func commandLineReadsTheAppsSavedScanOptions() throws {
        let defaults = fresh()
        // Nothing saved: the caller's fallback.
        #expect(AppSettings.savedScanOptions(in: defaults) == ScanOptions())
        #expect(AppSettings.savedScanOptions(in: nil) == ScanOptions())
        // What the app saved, exclusions included.
        let app = make(defaults)
        #expect(app.addExclusion(URL(filePath: "/Users/tester/Projects/keep")) == nil)
        let saved = AppSettings.savedScanOptions(in: defaults)
        #expect(saved.exclusions == app.scanOptions.exclusions)
        #expect(!saved.exclusions.isEmpty)
        // A field missing from what was saved takes its default; the rest still loads.
        defaults.set(Data(#"{"exclusions":["~/keep"]}"#.utf8), forKey: AppSettings.scanOptionsKey)
        #expect(AppSettings.savedScanOptions(in: defaults) == ScanOptions(exclusions: ["~/keep"]))
        // Unreadable: the fallback, and the caller is told (the CLI prints a note).
        defaults.set(Data("nope".utf8), forKey: AppSettings.scanOptionsKey)
        var told = false
        #expect(AppSettings.savedScanOptions(in: defaults, onUnreadable: { told = true }) == ScanOptions())
        #expect(told)
        // Nothing saved: not unreadable.
        told = false
        _ = AppSettings.savedScanOptions(in: fresh(), onUnreadable: { told = true })
        #expect(!told)
    }

    private func make(_ defaults: UserDefaults, login: FakeLoginItems = FakeLoginItems()) -> AppSettings {
        AppSettings(defaults: defaults, environment: environment, loginItems: login)
    }

    // MARK: defaults and persistence

    @Test func defaultsMatchTheDesign() {
        let settings = make(fresh())
        #expect(settings.appearance == .system)
        #expect(settings.preselectSafe)
        #expect(settings.showReviewItems)
        #expect(settings.includeBrowserCaches)
        #expect(settings.skipChangedWithinDays == 7)
        #expect(settings.includeExternalTrash)
        #expect(settings.exclusionRows.isEmpty)
        #expect(settings.alwaysConfirmEmptyTrash)
        #expect(!settings.openAtLogin)
        #expect(settings.loadProblem == nil)
    }

    @Test func settingsSurviveARelaunch() {
        let defaults = fresh()
        let first = make(defaults)
        first.appearance = .dark
        first.preselectSafe = false
        first.showReviewItems = false
        first.includeBrowserCaches = false
        first.skipChangedWithinDays = nil
        first.includeExternalTrash = false
        #expect(first.addExclusion(URL(filePath: "/Users/tester/Developer/keep-builds")) == nil)

        let second = make(defaults)
        #expect(second.appearance == .dark)
        #expect(!second.preselectSafe)
        #expect(!second.showReviewItems)
        #expect(!second.includeBrowserCaches)
        #expect(second.skipChangedWithinDays == nil)
        #expect(!second.includeExternalTrash)
        #expect(second.scanOptions.exclusions == ["/Users/tester/Developer/keep-builds"])
    }

    @Test func corruptScanSettingsFallBackToDefaultsAndSaySo() {
        let defaults = fresh()
        defaults.set(Data("not json".utf8), forKey: AppSettings.scanOptionsKey)
        let settings = make(defaults)
        #expect(settings.scanOptions == AppSettings.defaultScanOptions)
        #expect(settings.loadProblem == "Your scan settings couldn't be read, so Dustling went back to the defaults.")
        // The next change saves good settings and the note goes away.
        settings.includeExternalTrash = false
        #expect(settings.loadProblem == nil)
        #expect(make(defaults).loadProblem == nil)
    }

    @Test func unknownAppearanceFallsBackToSystem() {
        let defaults = fresh()
        defaults.set("sepia", forKey: AppSettings.appearanceKey)
        #expect(make(defaults).appearance == .system)
    }

    @Test func changesReachTheScanOptionsListener() {
        let settings = make(fresh())
        var seen: [ScanOptions] = []
        settings.onScanOptionsChanged = { seen.append($0) }
        settings.skipChangedWithinDays = 14
        _ = settings.addExclusion(URL(filePath: "/Volumes/Backup"))
        #expect(seen.count == 2)
        #expect(seen.last?.skipChangedWithinDays == 14)
        #expect(seen.last?.exclusions == ["/Volumes/Backup"])
    }

    // MARK: exclusions

    @Test func exclusionRowsShowHomeAsTildeAndAreIdentifiable() {
        let settings = make(fresh())
        _ = settings.addExclusion(URL(filePath: "/Users/tester/Library/Caches/com.apple.Music"))
        _ = settings.addExclusion(URL(filePath: "/Volumes/Backup"))
        let rows = settings.exclusionRows
        #expect(rows.map(\.display) == ["~/Library/Caches/com.apple.Music", "/Volumes/Backup"])
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.allSatisfy { $0.problem == nil })
    }

    @Test func duplicateAndProtectedFoldersAreNotAddedWithAReason() {
        let settings = make(fresh())
        #expect(settings.addExclusion(URL(filePath: "/Volumes/Backup")) == nil)
        #expect(settings.addExclusion(URL(filePath: "/Volumes/Backup/")) == "That folder is already excluded.")
        #expect(settings.addExclusion(URL(filePath: "/Users/tester/Documents"))
                == "Dustling never touches Documents anyway, so it doesn't need excluding.")
        #expect(settings.exclusionRows.count == 1)
    }

    @Test func unusableSavedEntriesAreShownWithTheirReason() {
        let defaults = fresh()
        let saved = ScanOptions(skipChangedWithinDays: 7, exclusions: ["relative/path", "/Volumes/Backup"])
        defaults.set(try! JSONEncoder().encode(saved), forKey: AppSettings.scanOptionsKey)
        let rows = make(defaults).exclusionRows
        #expect(rows.count == 2)
        #expect(rows[0].problem == "Ignored: not an absolute path")
        #expect(rows[1].problem == nil)
    }

    @Test func removingAnExclusionSaves() {
        let defaults = fresh()
        let settings = make(defaults)
        _ = settings.addExclusion(URL(filePath: "/Volumes/A"))
        _ = settings.addExclusion(URL(filePath: "/Volumes/B"))
        settings.removeExclusion(settings.exclusionRows[0])
        #expect(make(defaults).exclusionRows.map(\.display) == ["/Volumes/B"])
    }

    @Test func alwaysProtectedChipsFollowTheDesign() {
        #expect(AppSettings.alwaysProtected
                == ["Documents", "Desktop", "Pictures", "Music", "Movies", "iCloud Drive", "/System", "Other users"])
    }

    // MARK: what the junk scan covers

    @Test func scanTogglesFilterTheCatalog() {
        let settings = make(fresh())
        let ids: [JunkCategoryID] = [.browserCaches, .userCaches, .oldInstallers, .trash]
        settings.showReviewItems = false
        settings.includeBrowserCaches = false
        let shown = ids.filter { settings.scans($0, selection: Self.selection($0)) }
        #expect(shown == [.userCaches, .trash])
    }

    private static func selection(_ id: JunkCategoryID) -> Selection {
        switch id {
        case .oldInstallers: return .review
        case .trash: return .emptyTrashOnly
        default: return .preselected
        }
    }

    // MARK: open at login

    @Test func openAtLoginRegistersAndUnregisters() {
        let login = FakeLoginItems()
        let settings = make(fresh(), login: login)
        settings.setOpenAtLogin(true)
        #expect(settings.openAtLogin)
        settings.setOpenAtLogin(false)
        #expect(!settings.openAtLogin)
        #expect(login.calls == ["register", "unregister"])
        #expect(settings.loginItemNote == nil)
    }

    @Test func openAtLoginFailureIsSaidInPlainWords() {
        let login = FakeLoginItems()
        login.registerError = Boom()
        let settings = make(fresh(), login: login)
        settings.setOpenAtLogin(true)
        #expect(!settings.openAtLogin)
        #expect(settings.loginItemNote == "Dustling couldn't turn this on. The operation couldn't be completed.")
    }

    @Test func openAtLoginWaitingForApprovalSaysWhereToApprove() {
        let login = FakeLoginItems(.requiresApproval)
        let settings = make(fresh(), login: login)
        #expect(settings.openAtLogin)
        #expect(settings.loginItemNote
                == "macOS needs your OK. Turn on Dustling in System Settings > General > Login Items.")
        #expect(settings.loginItemNeedsApproval)
    }

    // MARK: fix round 1

    /// The home folder and ~/Library are protected themselves, not what's inside: they can be excluded.
    @Test func homeAndLibraryCanBeExcludedButProtectedTreesCannot() {
        let settings = make(fresh())
        #expect(settings.addExclusion(URL(filePath: "/Users/tester")) == nil)
        #expect(settings.addExclusion(URL(filePath: "/Users/tester/Library")) == nil)
        #expect(settings.addExclusion(URL(filePath: "/Users/tester/Pictures/Trips")) != nil)
        #expect(settings.addExclusion(URL(filePath: "/Users/someone/Library")) != nil)
        #expect(settings.addExclusion(URL(filePath: "/System/Library")) != nil)
        #expect(settings.exclusionRows.map(\.display) == ["~", "~/Library"])
    }

    /// A scan keeps the choice it started with: changing Settings later doesn't hide its tiles.
    @Test func scanChoiceIsASnapshot() {
        let settings = make(fresh())
        let taken = settings.scanChoice
        settings.showReviewItems = false
        settings.includeBrowserCaches = false
        #expect(taken.scans(.oldInstallers, selection: .review))
        #expect(taken.scans(.browserCaches, selection: .preselected))
        #expect(!settings.scanChoice.scans(.oldInstallers, selection: .review))
        #expect(!settings.scanChoice.scans(.browserCaches, selection: .preselected))
    }
}
