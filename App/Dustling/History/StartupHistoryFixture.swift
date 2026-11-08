#if DEBUG
import DustlingAppModel
import DustlingCore
import Foundation

/// DEBUG only. Sample data from the approved mockups (`SU` and `RUNS` in screens.html) for screenshots
/// of states this Mac can't show safely:
/// - `-DustlingStartupFixture normal|remove|changed`
/// - `-DustlingHistoryFixture runs|items|log|restored`
///
/// Nothing here reads or touches the disk: the models refuse to load, switch, remove or restore
/// while a fixture is on.
@MainActor enum StartupHistoryFixture {
    /// The Startup screen opens the Remove confirmation for the orphan.
    static var opensRemoveSheet = false
    /// The History tab to open.
    static var historyTab: HistoryView.Tab?
    /// All items rows to show checked.
    static var checkedItems: Set<String> = []
}

extension AppModels {
    func applyStartupHistoryFixtureFromLaunchArguments() {
        let defaults = UserDefaults.standard
        if let state = defaults.string(forKey: "DustlingStartupFixture") { showStartupFixture(state) }
        if let state = defaults.string(forKey: "DustlingHistoryFixture") { showHistoryFixture(state) }
    }

    private func showStartupFixture(_ state: String) {
        selection = .startupItems
        let agents = homeDirectory.appending(path: "Library/LaunchAgents")
        func item(
            _ label: String, _ scope: StartupScope, program: String, on: Bool = true
        ) -> StartupItem {
            let folder: URL
            switch scope {
            case .userAgent: folder = agents
            case .systemAgent: folder = URL(filePath: "/Library/LaunchAgents")
            case .systemDaemon: folder = URL(filePath: "/Library/LaunchDaemons")
            case .loginItem: folder = agents
            }
            return StartupItem(
                label: label, scope: scope, plistURL: folder.appending(path: "\(label).plist"), program: program,
                ownerAppName: nil, isEnabled: on, managedInSystemSettingsOnly: false)
        }
        let items = [
            item("com.google.GoogleUpdater.wake", .userAgent,
                 program: "/Users/Shared/Dustling fixture/GoogleUpdater.app/Contents/MacOS/GoogleUpdater"),
            item("com.microsoft.update.agent", .systemAgent,
                 program: "/Library/Application Support/Dustling fixture/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft AutoUpdate"),
            item("us.zoom.updater.login.check", .userAgent,
                 program: "/Library/Dustling fixture/Zoom updater.app/Contents/MacOS/Zoom updater", on: false),
            item("com.logi.optionsplus.updater", .userAgent,
                 program: "/Applications/Logi Options+.app/Contents/MacOS/Logi Options+ updater"),
            item("com.docker.vmnetd", .systemDaemon, program: "/Library/PrivilegedHelperTools/com.docker.vmnetd"),
            item("com.adobe.ARMDC.SMJobBlessHelper", .systemDaemon,
                 program: "/Library/PrivilegedHelperTools/com.adobe.ARMDC.SMJobBlessHelper"),
        ]
        let owners = [
            items[0].id: "Google Chrome", items[1].id: "Microsoft Teams", items[2].id: "Zoom",
            items[4].id: "Docker Desktop", items[5].id: "Adobe Acrobat Reader",
        ]
        startup.showFixture(items: items, orphanIDs: [items[3].id], owners: owners)
        StartupHistoryFixture.opensRemoveSheet = state == "remove"
        if state == "changed" {
            let record = RunRecord(
                startedAt: .now, kind: .startupChange,
                entries: [JournalEntry(originalPath: items[2].plistURL!.path(percentEncoded: false), bytes: 0,
                                       outcome: .skipped(reason: "disabled"))],
                restorable: false)
            startup.showFixtureResult(StartupChange(
                record: record, result: StartupScreen.changeResult(record, name: "Zoom updater", action: .toggle),
                action: .toggle, itemName: "Zoom updater"))
        }
    }

    private func showHistoryFixture(_ state: String) {
        selection = .history
        let home = homeDirectory.path(percentEncoded: false)
        let trash = home + "/.Trash/"
        let gb = 1_000_000_000.0
        let calendar = Calendar.current
        func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: .now)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        func moved(_ path: String, _ size: Double, restored: Bool = false) -> JournalEntry {
            let full = path.hasPrefix("~") ? home + path.dropFirst() : path
            return JournalEntry(
                originalPath: full, bytes: UInt64(size * gb),
                outcome: .movedToTrash(trashedPath: trash + URL(filePath: full).lastPathComponent), restored: restored)
        }
        let junk = RunRecord(startedAt: at(daysAgo: 0, 19, 4), kind: .junkClean, entries: [
            moved("~/Library/Developer/Xcode/DerivedData/Dustling-gbhyqz", 3.41),
            moved("~/Library/Developer/CoreSimulator/Volumes/iOS_21E213", 6.02),
            JournalEntry(originalPath: "/Library/Caches/com.apple.iconservices.store", bytes: 412_000_000, outcome: .needsAdmin),
            JournalEntry(originalPath: home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A1F2",
                         bytes: 0, outcome: .skipped(reason: "in use by Mail")),
            JournalEntry(originalPath: home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/7C09",
                         bytes: 0, outcome: .skipped(reason: "in use by Mail")),
            moved("~/Library/Caches/Homebrew/downloads", 2.06),
            moved("~/Library/Logs/DiagnosticReports", 1.07),
        ], restorable: true)
        let apps = RunRecord(startedAt: at(daysAgo: 0, 18, 40), kind: .uninstall(appName: "Docker Desktop"), entries: [
            moved("/Applications/Docker.app", 2.08),
            moved("~/Library/Containers/com.docker.docker", 11.46),
            moved("~/Library/Caches/com.docker.docker", 0.084),
            JournalEntry(originalPath: "/Library/LaunchDaemons/com.docker.vmnetd.plist", bytes: 4_096, outcome: .needsAdmin),
        ], restorable: true)
        let turnedOff = RunRecord(startedAt: at(daysAgo: 1, 21, 20), kind: .startupChange, entries: [
            JournalEntry(originalPath: home + "/Library/LaunchAgents/us.zoom.updater.login.check.plist", bytes: 0,
                         outcome: .skipped(reason: "disabled")),
        ], restorable: false)
        let removed = RunRecord(startedAt: at(daysAgo: 1, 21, 12), kind: .startupChange, entries: [
            moved("~/Library/LaunchAgents/com.logi.optionsplus.updater.plist", 0.000004),
        ], restorable: true)
        let empty = RunRecord(startedAt: at(daysAgo: 3, 9, 30), kind: .emptyTrash, entries: [
            JournalEntry(originalPath: trash + "Unity Hub.app", bytes: 3_900_000_000, outcome: .deleted),
            JournalEntry(originalPath: trash + "DerivedData", bytes: 12_400_000_000, outcome: .deleted),
            JournalEntry(originalPath: trash + "locked.db", bytes: 0, outcome: .failed(reason: "it is in use")),
        ], restorable: false)
        let old = RunRecord(startedAt: at(daysAgo: 4, 10, 22), kind: .junkClean, entries: [
            moved("~/Library/Developer/Xcode/DerivedData", 12.4),
        ], restorable: false)
        var runs = [junk, apps, turnedOff, removed, empty, old]
        if state == "restored" {
            runs[1].entries[1].restored = true
        }
        history.showFixture(runs)
        switch state {
        case "items":
            StartupHistoryFixture.historyTab = .allItems
            StartupHistoryFixture.checkedItems = Set(history.allItems.filter { $0.runID == apps.id }.prefix(2).map(\.id))
        case "log": StartupHistoryFixture.historyTab = .log
        case "restored":
            history.showFixtureRestore(HistoryScreen.restoreSummary([
                .restored(home + "/Library/Containers/com.docker.docker"),
                .conflict("/Applications/Docker.app"),
            ]))
        default: StartupHistoryFixture.historyTab = .runs
        }
    }
}
#endif
