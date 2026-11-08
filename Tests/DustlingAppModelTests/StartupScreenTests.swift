import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

struct StartupScreenTests {
    private func item(
        _ label: String, _ scope: StartupScope = .userAgent, program: String? = nil, on: Bool = true,
        plist: String? = nil, owner: String? = nil
    ) -> StartupItem {
        StartupItem(
            label: label, scope: scope, plistURL: URL(filePath: plist ?? "/Users/k/Library/LaunchAgents/\(label).plist"),
            program: program, ownerAppName: owner, isEnabled: on, managedInSystemSettingsOnly: false)
    }

    private func app(_ path: String, _ name: String) -> InstalledApp {
        InstalledApp(
            url: URL(filePath: path, directoryHint: .isDirectory), displayName: name, bundleID: nil, teamID: nil,
            executableName: nil, steamAppID: nil, bytes: 0, lastUsed: nil)
    }

    // MARK: names and owners

    @Test func nameComesFromTheInnermostAppOrTheProgramElseTheLabel() {
        #expect(StartupScreen.displayName(item(
            "com.microsoft.update.agent",
            program: "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/"
                + "Microsoft Update Assistant.app/Contents/MacOS/Microsoft Update Assistant")) == "Microsoft Update Assistant")
        #expect(StartupScreen.displayName(item("homebrew.mxcl.redis", program: "/opt/homebrew/opt/redis/bin/redis-server"))
            == "redis-server")
        // A system tool says nothing about the item: the label does.
        #expect(StartupScreen.displayName(item("com.displaylink.agent", program: "/usr/bin/open")) == "com.displaylink.agent")
        #expect(StartupScreen.displayName(item("app.dustling.test", program: "/usr/bin/true")) == "app.dustling.test")
        #expect(StartupScreen.displayName(item("com.x.bare", program: "sometool")) == "com.x.bare")
        #expect(StartupScreen.displayName(item("com.x.none")) == "com.x.none")
    }

    @Test func ownerIsTheInstalledAppHoldingTheProgram() {
        let apps = [app("/Applications/OneDrive.app", "OneDrive"), app("/Applications/Zoom.app", "zoom.us")]
        let inside = item("com.microsoft.SyncReporter", program: "/Applications/OneDrive.app/Contents/SyncReporter.app/Contents/MacOS/SyncReporter")
        #expect(StartupScreen.owner(of: inside, apps: apps)?.name == "OneDrive")
        #expect(StartupScreen.owner(of: inside, apps: apps)?.appURL?.path == "/Applications/OneDrive.app")
        // Not an installed app, but the program sits in an app bundle that is there.
        let bundle = item("com.x", program: "/Library/Application Support/X/X Helper.app/Contents/MacOS/X Helper")
        #expect(StartupScreen.owner(of: bundle, apps: apps, isPresent: { _ in true })?.name == "X Helper")
        #expect(StartupScreen.owner(of: bundle, apps: apps, isPresent: { _ in false }) == nil)
        // The scanner's own answer wins.
        #expect(StartupScreen.owner(of: item("a", program: "/x/y", owner: "Known"), apps: apps)?.name == "Known")
        #expect(StartupScreen.owner(of: item("a", program: "/usr/bin/true"), apps: apps) == nil)
        // "/Applications/OneDrive.app2/…" is not inside OneDrive.app.
        #expect(StartupScreen.owner(of: item("a", program: "/Applications/OneDrive.app2/x"), apps: apps) == nil)
    }

    @Test func removedAppNameComesFromTheProgramPath() {
        #expect(StartupScreen.removedAppName(program: "/Applications/Logi Options+.app/Contents/MacOS/updater") == "Logi Options+")
        #expect(StartupScreen.removedAppName(program: "/opt/gone/tool") == nil)
        #expect(StartupScreen.removedAppName(program: nil) == nil)
    }

    // MARK: groups and filter

    @Test func groupHeadersFollowTheDesign() {
        #expect(StartupScreen.heading(.loginItems) == "Login items")
        #expect(StartupScreen.caption(.loginItems) == "Open when you log in")
        #expect(StartupScreen.heading(.agents) == "Launch agents")
        #expect(StartupScreen.caption(.agents) == "Run in the background for your account")
        #expect(StartupScreen.heading(.daemons) == "Launch daemons")
        #expect(StartupScreen.caption(.daemons) == "System services, changed through the helper")
        #expect(StartupScreen.onCount(on: 3, total: 4) == "3 of 4 on")
        #expect(StartupScreen.kindName(.userAgent) == "Launch agent")
        #expect(StartupScreen.kindName(.systemAgent) == "Launch agent")
        #expect(StartupScreen.kindName(.systemDaemon) == "Launch daemon")
        #expect(StartupScreen.kindName(.loginItem) == "Login item")
    }

    @Test func filterSegmentsCountItemsButLoginItemsCantBeCounted() {
        let items = [
            item("a"), item("b", on: false), item("c", .systemAgent), item("d", .systemDaemon),
        ]
        let segments = StartupScreen.segments(items)
        #expect(segments.map(\.label) == ["All 4", "Login items", "Agents 3", "Daemons 1"])
        #expect(segments.map(\.filter) == [.all, .loginItems, .agents, .daemons])
        #expect(StartupScreen.Filter.agents.shows(.agents))
        #expect(!StartupScreen.Filter.agents.shows(.daemons))
        #expect(StartupScreen.Filter.all.shows(.loginItems))
    }

    @Test func subtitleCountsWhatIsOn() {
        #expect(StartupScreen.subtitle([item("a"), item("b", on: false)], isLoading: false) == "2 items, 1 turned on")
        #expect(StartupScreen.subtitle([item("a")], isLoading: false) == "1 item, 1 turned on")
        #expect(StartupScreen.subtitle([], isLoading: false) == "No startup items found")
        #expect(StartupScreen.subtitle([], isLoading: true) == "Looking for startup items…")
    }

    // MARK: badges

    @Test func badges() {
        #expect(StartupScreen.badge(scope: .userAgent, orphaned: true, systemSettingsOnly: false) == .appNotFound)
        #expect(StartupScreen.badge(scope: .loginItem, orphaned: false, systemSettingsOnly: true) == .inSystemSettings)
        #expect(StartupScreen.badge(scope: .systemDaemon, orphaned: false, systemSettingsOnly: false) == .helper)
        #expect(StartupScreen.badge(scope: .systemAgent, orphaned: false, systemSettingsOnly: false) == .helper)
        #expect(StartupScreen.badge(scope: .userAgent, orphaned: false, systemSettingsOnly: false) == nil)
        // An orphan that needs the helper is still flagged as orphaned first.
        #expect(StartupScreen.badge(scope: .systemDaemon, orphaned: true, systemSettingsOnly: false) == .appNotFound)
        #expect(StartupScreen.Badge.appNotFound.text == "App not found")
        #expect(StartupScreen.Badge.inSystemSettings.text == "In System Settings")
        #expect(StartupScreen.Badge.helper.text == "Helper")
        #expect(StartupScreen.Badge.helper.help == "Needs the cleanup helper (coming in a later version)")
    }

    // MARK: orphan banner

    @Test func orphanBannerForOneItemNamesTheRemovedApp() throws {
        let gone = item("com.logi.optionsplus.updater", program: "/Applications/Logi Options+.app/Contents/MacOS/updater")
        let banner = try #require(StartupScreen.orphanBanner([gone], canChange: { _ in true }))
        #expect(banner.title == "Logi Options+ was uninstalled, but its startup item still runs.")
        #expect(banner.message == "It can't do anything useful without the app. Turning it off is reversible, "
            + "and removing it moves it to the Trash.")
        #expect(banner.showsTurnOff)
        #expect(banner.showsRemove)
    }

    @Test func orphanBannerWithoutAnAppNameAndWhenOff() throws {
        let off = item("com.gone.tool", program: "/opt/gone/tool", on: false)
        let banner = try #require(StartupScreen.orphanBanner([off], canChange: { _ in true }))
        #expect(banner.title == "The program behind tool is gone, but the item is still here.")
        #expect(!banner.showsTurnOff)   // already off
        #expect(banner.showsRemove)
        #expect(StartupScreen.orphanBanner([], canChange: { _ in true }) == nil)
    }

    @Test func orphanBannerForSeveralItemsAndForHelperItems() throws {
        let a = item("a", program: "/Applications/A.app/Contents/MacOS/a")
        let d = item("d", .systemDaemon, program: "/Applications/D.app/Contents/MacOS/d")
        let several = try #require(StartupScreen.orphanBanner([a, d], canChange: { $0.scope == .userAgent }))
        #expect(several.title == "2 startup items belong to apps that were uninstalled.")
        #expect(several.showsTurnOff)
        let helperOnly = try #require(StartupScreen.orphanBanner([d], canChange: { _ in false }))
        #expect(!helperOnly.showsTurnOff)
        #expect(!helperOnly.showsRemove)
        #expect(helperOnly.message.contains("Needs the cleanup helper (coming in a later version)"))
    }

    // MARK: remove

    @Test func removeConfirmation() {
        let text = StartupScreen.removeConfirm(name: "Logi Options+ updater", canTakeOutOfTrash: true)
        #expect(text.title == "Move Logi Options+ updater to the Trash?")
        #expect(text.message == "It stops now and won't start at your next login. You can put it back from History "
            + "until you empty the Trash.")
        #expect(text.limitedNote == nil)
        #expect(text.button == "Move to Trash")
        let limited = StartupScreen.removeConfirm(name: "x", canTakeOutOfTrash: false)
        #expect(limited.limitedNote == CleanupGate.limitedNote)
        #expect(limited.message == "It stops now and won't start at your next login.")
    }

    // MARK: result of a change

    @Test func changeResultsSayWhatHappened() {
        func record(_ outcomes: [DeletionOutcome]) -> RunRecord {
            RunRecord(
                startedAt: .now, kind: .startupChange,
                entries: outcomes.map { JournalEntry(originalPath: "/p/x.plist", bytes: 0, outcome: $0) },
                restorable: false)
        }
        let off = StartupScreen.changeResult(record([.skipped(reason: "disabled")]), name: "Zoom updater", action: .toggle)
        #expect(off == StartupScreen.ChangeResult(success: true, title: "Turned off Zoom updater.", message: nil))
        let on = StartupScreen.changeResult(record([.skipped(reason: "enabled")]), name: "Zoom updater", action: .toggle)
        #expect(on.title == "Turned on Zoom updater.")
        let failed = StartupScreen.changeResult(
            record([.failed(reason: "launchctl disable failed: nope")]), name: "Zoom updater", action: .toggle)
        #expect(failed == StartupScreen.ChangeResult(
            success: false, title: "Zoom updater wasn't changed.", message: "launchctl disable failed: nope"))
        let helper = StartupScreen.changeResult(record([.needsAdmin]), name: "D", action: .toggle)
        #expect(helper.message == "Needs the cleanup helper (coming in a later version)")
        let moved = StartupScreen.changeResult(
            record([.movedToTrash(trashedPath: "/t/x.plist")]), name: "Logi updater", action: .remove)
        #expect(moved == StartupScreen.ChangeResult(success: true, title: "Moved Logi updater to the Trash.", message: nil))
        let unloadFailed = StartupScreen.changeResult(
            record([.movedToTrash(trashedPath: "/t/x.plist"), .failed(reason: "could not unload: busy")]),
            name: "Logi updater", action: .remove)
        #expect(!unloadFailed.success)
        #expect(unloadFailed.title == "Moved Logi updater to the Trash, with a problem.")
        #expect(unloadFailed.message == "could not unload: busy")
        let stopped = StartupScreen.changeResult(
            record([.failed(reason: "disk full.")]), name: "X", action: .remove, stoppedFirst: true)
        #expect(stopped.message == "disk full. It was stopped but will start again at your next login.")
        let skipped = StartupScreen.changeResult(record([.skipped(reason: "protected")]), name: "X", action: .remove)
        #expect(skipped == StartupScreen.ChangeResult(success: false, title: "X wasn't moved.", message: "protected"))
    }

    @Test func issuesAreSummarisedInPlainWords() {
        let issues: [ScanIssue] = [
            .unreadable(URL(filePath: "/Users/k/Library/LaunchAgents/bad.plist")),
            .commandFailed(command: "launchctl print-disabled system", reason: "denied"),
        ]
        #expect(StartupScreen.issueSummary(issues, home: "/Users/k")
            == "~/Library/LaunchAgents/bad.plist couldn't be read. launchctl print-disabled system failed: denied.")
        let many = Array(repeating: ScanIssue.unreadable(URL(filePath: "/x")), count: 5)
        #expect(StartupScreen.issueSummary(many, home: "/Users/k").hasSuffix(", and 2 more."))
    }
}
