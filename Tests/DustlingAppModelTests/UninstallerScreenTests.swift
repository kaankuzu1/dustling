import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

struct UninstallerScreenTests {
    private let gb: UInt64 = 1_000_000_000

    private func app(_ name: String, bytes: UInt64 = 1_000_000_000, lastUsed: Date? = nil, link: URL? = nil,
                     steam: String? = nil, bundleID: String? = "com.test.x") -> InstalledApp {
        InstalledApp(
            url: URL(filePath: "/Applications/\(name).app"), displayName: name, bundleID: bundleID, teamID: nil,
            executableName: nil, steamAppID: steam, bytes: bytes, lastUsed: lastUsed, linkTarget: link)
    }

    private func row(_ app: InstalledApp, counting: Bool = false, leftovers: Int = 0, total: UInt64 = 0,
                     label: String? = nil) -> AppRow {
        AppRow(app: app, isCounting: counting, leftoverCount: leftovers, totalBytes: total, label: label, warning: nil)
    }

    private func leftover(_ path: String, _ kind: LeftoverKind, bytes: UInt64, data: Bool = false,
                          admin: Bool = false, match: MatchStrength = .exact, note: String? = nil) -> Leftover {
        Leftover(url: URL(filePath: path), kind: kind, match: match, mayContainUserData: data, requiresAdmin: admin,
                 bytes: bytes, note: note)
    }

    // MARK: list

    @Test func appCaptionLabelsSteamShortcutsAndCounts() {
        #expect(UninstallerScreen.appCaption(row(app("A"), counting: true)) == "Looking for leftovers…")
        #expect(UninstallerScreen.appCaption(row(app("A"))) == "No leftovers")
        #expect(UninstallerScreen.appCaption(row(app("A"), leftovers: 1)) == "1 leftover")
        #expect(UninstallerScreen.appCaption(row(app("A"), leftovers: 10)) == "10 leftovers")
        #expect(UninstallerScreen.appCaption(row(app("P"), leftovers: 3, label: "Steam game"))
            == "Steam game, no bundle ID")
        #expect(UninstallerScreen.appCaption(row(app("S"), label: "Shortcut")) == "Shortcut, only the link is removed")
    }

    @Test func lastUsedReadsLikeTheMockup() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ days: Double) -> String? {
            UninstallerScreen.lastUsed(now.addingTimeInterval(-days * 86_400), now: now, calendar: calendar)
        }
        #expect(UninstallerScreen.lastUsed(nil, now: now, calendar: calendar) == nil)
        #expect(ago(0) == "Today")
        #expect(ago(1) == "Yesterday")
        #expect(ago(5) == "5 days ago")
        #expect(ago(15) == "2 weeks ago")
        #expect(ago(130) == "4 months ago")
        #expect(ago(400) == "1 year ago")
    }

    @Test func arrangeFiltersAndSorts() {
        let now = Date()
        let rows = [
            row(app("Zoom", lastUsed: now.addingTimeInterval(-100)), total: 2 * gb),
            row(app("figma", lastUsed: now.addingTimeInterval(-50)), total: 5 * gb),
            row(app("Arc"), total: 1 * gb),
        ]
        #expect(UninstallerScreen.arrange(rows, query: "", sort: .size).map(\.app.displayName) == ["figma", "Zoom", "Arc"])
        #expect(UninstallerScreen.arrange(rows, query: "", sort: .name).map(\.app.displayName) == ["Arc", "figma", "Zoom"])
        // Never-used (unknown) apps go last.
        #expect(UninstallerScreen.arrange(rows, query: "", sort: .lastUsed).map(\.app.displayName)
            == ["figma", "Zoom", "Arc"])
        #expect(UninstallerScreen.arrange(rows, query: " FIG ", sort: .size).map(\.app.displayName) == ["figma"])
    }

    // MARK: leftovers

    @Test func badgesAndKindNamesFollowTheDesign() {
        #expect(UninstallerScreen.badge(.teamID).text == "Team ID match")
        #expect(UninstallerScreen.badge(.teamID).style == .neutral)
        #expect(UninstallerScreen.badge(.system).text == "System")
        #expect(UninstallerScreen.badge(.system).style == .admin)
        #expect(UninstallerScreen.badge(.nameMatch).text == "Name match")
        #expect(UninstallerScreen.badge(.yourData).text == "May contain your data")
        #expect(UninstallerScreen.badge(.yourData).style == .warning)
        #expect(UninstallerScreen.kindName(.container) == "Container data")
        #expect(UninstallerScreen.kindName(.savedState) == "Saved window state")
        #expect(UninstallerScreen.kindName(.privilegedHelper) == "Privileged helper")
    }

    @Test func rowNotesSayWhyARowIsUncheckedOrDisabled() {
        let excluded = LeftoverRow(
            leftover: leftover("/u/Library/Caches/a", .caches, bytes: 1), checked: false, badges: [], warning: nil,
            disabledReason: "excluded in Settings")
        #expect(UninstallerScreen.note(for: excluded) == "Excluded in Settings")
        let contains = LeftoverRow(
            leftover: leftover("/u/Library/Caches/a", .caches, bytes: 1), checked: false, badges: [], warning: nil,
            disabledReason: "contains a folder excluded in Settings")
        #expect(UninstallerScreen.note(for: contains) == "Contains a folder excluded in Settings")
        let fuzzy = LeftoverRow(
            leftover: leftover("/u/.docker", .applicationSupport, bytes: 1, match: .nameBased), checked: false,
            badges: [.nameMatch], warning: nil, disabledReason: nil)
        #expect(UninstallerScreen.note(for: fuzzy) == "Matched by name only, so it isn't checked")
        let helper = LeftoverRow(
            leftover: leftover("/Library/LaunchDaemons/x.plist", .launchDaemon, bytes: 1, admin: true), checked: true,
            badges: [.system], warning: nil, disabledReason: nil)
        #expect(UninstallerScreen.note(for: helper) == "Needs your Mac password")
        let plain = LeftoverRow(
            leftover: leftover("/u/Library/Caches/b", .caches, bytes: 1), checked: true, badges: [], warning: nil,
            disabledReason: nil)
        #expect(UninstallerScreen.note(for: plain) == nil)
    }

    @Test func detailTotalsCountOnlyWhatWillMove() {
        let target = app("Docker", bytes: 2 * gb)
        let rows = [
            LeftoverRow(leftover: leftover("/a", .caches, bytes: 1 * gb), checked: true, badges: [], warning: nil,
                        disabledReason: nil),
            LeftoverRow(leftover: leftover("/b", .container, bytes: 10 * gb, data: true), checked: false,
                        badges: [.yourData], warning: nil, disabledReason: nil),
            LeftoverRow(leftover: leftover("/c", .launchDaemon, bytes: 3 * gb, admin: true), checked: true,
                        badges: [.system], warning: nil, disabledReason: nil),
            LeftoverRow(leftover: leftover("/d", .caches, bytes: 4 * gb), checked: false, badges: [], warning: nil,
                        disabledReason: "excluded in Settings"),
        ]
        let appRow = row(target, leftovers: 4, total: 20 * gb)
        let totals = UninstallerScreen.totals(app: appRow, leftovers: rows)
        #expect(totals.selected == 3 * gb)   // the app and the cache; the helper item stays
        #expect(totals.found == 20 * gb)
        // A shortcut frees nothing but the link.
        let link = row(app("S", bytes: 5 * gb, link: URL(filePath: "/x/S.app")), total: 0, label: "Shortcut")
        #expect(UninstallerScreen.totals(app: link, leftovers: []).selected == 0)
    }

    // MARK: selection and confirmation

    private func confirm(
        perApp: [ConfirmModel.PerApp], data: [ConfirmModel.DataWarning] = [], running: [String] = [],
        agents: Int = 0, admin: Int = 0, ready: Bool = true, limited: String? = nil
    ) -> ConfirmModel {
        ConfirmModel(
            plan: [], ready: ready, note: ready ? nil : "Still looking for leftovers", perApp: perApp,
            dataWarnings: data, runningApps: running, launchAgents: agents, adminItems: admin,
            adminNote: admin > 0 ? "Needs your Mac password" : nil,
            totalBytes: perApp.reduce(0) { $0 + $1.bytes }, limitedNote: limited)
    }

    private func per(_ name: String, items: Int, data: Int = 0, bytes: UInt64) -> ConfirmModel.PerApp {
        .init(name: name, items: items, dataItems: data, adminItems: 0, bytes: bytes)
    }

    private func dataWarning(_ app: String) -> ConfirmModel.DataWarning {
        .init(appName: app, itemName: "com.docker.docker", kind: .container, bytes: 11_460_000_000, text: "")
    }

    @Test func selectionLineMentionsCheckedData() {
        let none = UninstallerScreen.selectionLine(confirm(perApp: []))
        #expect(none.title == "No apps selected")
        let one = UninstallerScreen.selectionLine(confirm(perApp: [per("Zoom", items: 3, bytes: gb)]))
        #expect(one.title == "1 app selected, 1 GB")
        #expect(one.caption == "Apps and their leftovers move to the Trash together.")
        let data = UninstallerScreen.selectionLine(confirm(
            perApp: [per("Docker", items: 9, data: 1, bytes: 2 * gb), per("Teams", items: 4, bytes: gb)],
            data: [dataWarning("Docker")]))
        #expect(data.title == "2 apps selected, 3 GB")
        #expect(data.caption == "Includes Docker's container data you checked.")
        let counting = UninstallerScreen.selectionLine(confirm(perApp: [per("Zoom", items: 1, bytes: gb)], ready: false))
        #expect(counting.caption == "Still looking for leftovers")
    }

    /// A name too long for the button isn't put on it (the notes still name the app).
    @Test func confirmButtonLeavesOutALongAppName() {
        let name = "An App With An Extremely Long Name"
        let text = ConfirmText.make(confirm(perApp: [per(name, items: 2, bytes: gb)], running: [name]))
        #expect(text.button == "Quit 1 app and move to Trash")
        #expect(text.notes.contains { $0.contains(name) })
        let fits = String(repeating: "x", count: ConfirmText.buttonNameLimit)
        #expect(ConfirmText.make(confirm(perApp: [per(fits, items: 1, bytes: gb)], running: [fits])).button
            == "Quit \(fits) and move to Trash")
    }

    @Test func confirmTextNamesTheRunningAppOnTheButton() {
        let one = ConfirmText.make(confirm(perApp: [per("Docker Desktop", items: 9, data: 1, bytes: 13 * gb)],
                                           data: [dataWarning("Docker Desktop")], running: ["Docker Desktop"], agents: 1))
        #expect(one.title == "Move Docker Desktop to the Trash?")
        #expect(one.message == "Everything below goes to the Trash. You can put it back until you empty the Trash.")
        #expect(one.apps.map(\.items) == ["10 items"])
        #expect(one.dataHeading == "1 item may contain your data:")
        #expect(one.dataLines == ["Docker Desktop container data, 11.46 GB. It is included because you checked it."])
        #expect(one.notes == [
            "Docker Desktop is running. Dustling will quit it first.",
            "1 launch agent is unloaded before it moves.",
        ])
        #expect(one.button == "Quit Docker Desktop and move to Trash")
        #expect(one.total == "13 GB")
        #expect(one.limitedNote == nil)

        let three = ConfirmText.make(confirm(
            perApp: [per("A", items: 1, bytes: gb), per("B", items: 2, bytes: gb), per("C", items: 1, bytes: gb)],
            running: ["A", "B"], admin: 2))
        #expect(three.title == "Move 3 apps to the Trash?")
        #expect(three.dataHeading == nil)
        #expect(three.notes == [
            "A and B are running. Dustling will quit them first.",
            "2 items belong to the system. Dustling will ask for your Mac password to move them.",
        ])
        #expect(three.button == "Quit 2 apps and move to Trash")
        let single = ConfirmText.make(confirm(perApp: [per("A", items: 1, bytes: gb)], admin: 1))
        #expect(single.notes == ["1 item belongs to the system. Dustling will ask for your Mac password to move it."])
        // Without Full Disk Access Dustling can't run the password step, so it doesn't promise to ask.
        let limited = ConfirmText.make(confirm(perApp: [per("A", items: 1, bytes: gb)], admin: 1, limited: "x"))
        #expect(limited.notes == [
            "1 item belongs to the system. It needs Full Disk Access, then your Mac password, so it stays where it is.",
        ])
        let limitedTwo = ConfirmText.make(confirm(perApp: [per("A", items: 1, bytes: gb)], admin: 2, limited: "x"))
        #expect(limitedTwo.notes == [
            "2 items belong to the system. They need Full Disk Access, then your Mac password, so they stay where they are.",
        ])

        let quiet = ConfirmText.make(confirm(perApp: [per("A", items: 1, bytes: gb)]))
        #expect(quiet.button == "Move to Trash")
        #expect(quiet.apps.map(\.items) == ["1 item"])
    }

    /// The confirm sheet's middle scrolls, so every checked data item is named; running apps are
    /// still counted past three to keep the note short.
    @Test func confirmTextNamesEveryDataItemAndCountsManyRunningApps() {
        let names = (1...50).map { "App \($0)" }
        let text = ConfirmText.make(confirm(
            perApp: names.map { per($0, items: 1, data: 1, bytes: gb) },
            data: names.map { dataWarning($0) }, running: names))
        #expect(text.dataHeading == "50 items may contain your data:")
        #expect(text.dataLines.count == 50)
        #expect(text.dataLines.last?.hasSuffix("They are included because you checked them.") == true)
        #expect(text.notes.first == "App 1, App 2, App 3 and 47 other apps are running. Dustling will quit them first.")
        #expect(text.button == "Quit 50 apps and move to Trash")

        let four = ConfirmText.make(confirm(perApp: [per("A", items: 1, bytes: gb)], running: ["A", "B", "C", "D"]))
        #expect(four.notes.first == "A, B, C and 1 other app are running. Dustling will quit them first.")
        let three = ConfirmText.make(confirm(perApp: [per("A", items: 1, bytes: gb)], running: ["A", "B", "C"]))
        #expect(three.notes.first == "A, B and C are running. Dustling will quit them first.")
    }

    @Test func confirmTextWarnsWhenItCantPutBack() {
        let text = ConfirmText.make(confirm(perApp: [per("A", items: 1, bytes: gb)], limited: CleanupGate.limitedNote))
        #expect(text.limitedNote == CleanupGate.limitedNote)
        #expect(text.message == "Everything below goes to the Trash.")
    }

    // MARK: progress

    private func plan() -> [ConfirmModel.Planned] {
        [
            .init(app: app("Docker"), leftovers: [
                leftover("/u/Library/Caches/com.docker", .caches, bytes: 100),
                leftover("/Library/LaunchDaemons/com.docker.plist", .launchDaemon, bytes: 5, admin: true),
            ]),
            .init(app: app("Teams"), leftovers: [leftover("/u/Library/Caches/com.teams", .caches, bytes: 50)]),
        ]
    }

    @Test func progressGoesAppByAppItemByItem() {
        var progress = UninstallProgress(plan: plan())
        let docker = progress.apps[0].id, teams = progress.apps[1].id
        #expect(progress.apps.map(\.state) == [.waiting, .waiting])
        #expect(progress.apps[0].items.map(\.title) == ["Application", "Caches", "Launch daemon"])

        progress.quitting(docker)
        #expect(progress.apps[0].state == .quitting)
        #expect(progress.current?.app.displayName == "Docker")
        progress.begin(docker)
        #expect(progress.apps[0].items.map(\.state) == [.moving, .waiting, .waiting])

        progress.record(URL(filePath: "/Applications/Docker.app"), .movedToTrash(trashedPath: "/t/Docker.app"), in: docker)
        #expect(progress.apps[0].items[0].state == .finished(.movedToTrash(trashedPath: "/t/Docker.app")))
        #expect(progress.apps[0].items[1].state == .moving)
        #expect(progress.bytesMoved == 1_000_000_000)
        #expect(progress.apps[0].doneCount == 1)

        let record = RunRecord(startedAt: Date(), kind: .uninstall(appName: "Docker"), entries: [
            JournalEntry(originalPath: "/Applications/Docker.app", bytes: 1_000_000_000,
                         outcome: .movedToTrash(trashedPath: "/t/Docker.app")),
            JournalEntry(originalPath: "/u/Library/Caches/com.docker", bytes: 120,
                         outcome: .movedToTrash(trashedPath: "/t/com.docker")),
            JournalEntry(originalPath: "/Library/LaunchDaemons/com.docker.plist", bytes: 5, outcome: .needsAdmin),
        ], restorable: true)
        progress.finish(docker, record: record)
        #expect(progress.apps[0].state == .finished(removed: true))
        #expect(progress.apps[0].items.map(\.state) == [
            .finished(.movedToTrash(trashedPath: "/t/Docker.app")),
            .finished(.movedToTrash(trashedPath: "/t/com.docker")), .finished(.needsAdmin),
        ])
        // Sizes come from what the record says moved.
        #expect(progress.bytesMoved == 1_000_000_120)
        #expect(progress.appsDone == 1)

        // A late item callback for a finished app changes nothing.
        progress.record(URL(filePath: "/u/Library/Caches/com.docker"), .failed(reason: "late"), in: docker)
        #expect(progress.apps[0].items[1].state == .finished(.movedToTrash(trashedPath: "/t/com.docker")))

        progress.stopRemaining()
        #expect(progress.apps[1].state == .stopped)
        #expect(progress.apps[1].id == teams)
        #expect(progress.current == nil)
    }

    @Test func progressMarksAnAppThatStayedAsNotRemoved() {
        var progress = UninstallProgress(plan: plan())
        let docker = progress.apps[0].id
        progress.quitting(docker)
        let record = RunRecord(startedAt: Date(), kind: .uninstall(appName: "Docker"), entries: [
            JournalEntry(originalPath: "/Applications/Docker.app", bytes: 1, outcome: .skipped(reason: "still running after Dustling asked it to quit")),
        ], restorable: false)
        progress.finish(docker, record: record)
        #expect(progress.apps[0].state == .finished(removed: false))
        #expect(progress.bytesMoved == 0)
    }

    // MARK: summary

    @Test func summaryComesFromTheRecordsOnly() {
        let home = URL(filePath: "/Users/k")
        let docker = RunRecord(startedAt: Date(), kind: .uninstall(appName: "Docker"), entries: [
            JournalEntry(originalPath: "/Applications/Docker.app", bytes: 2 * gb, outcome: .movedToTrash(trashedPath: "/t/a")),
            JournalEntry(originalPath: "/Users/k/Library/Caches/com.docker", bytes: gb, outcome: .movedToTrash(trashedPath: "/t/b")),
            JournalEntry(originalPath: "/Users/k/Library/Logs/Docker", bytes: 5, outcome: .failed(reason: "permission denied")),
            JournalEntry(originalPath: "/Library/LaunchDaemons/com.docker.plist", bytes: 5, outcome: .needsAdmin),
        ], restorable: true)
        let zoom = RunRecord(startedAt: Date(), kind: .uninstall(appName: "Zoom"), entries: [
            JournalEntry(originalPath: "/Applications/Zoom.app", bytes: gb, outcome: .skipped(reason: "still running after Dustling asked it to quit")),
            JournalEntry(originalPath: "/Users/k/Library/Caches/zoom", bytes: 1,
                         outcome: .skipped(reason: "kept because the app itself was not removed")),
        ], restorable: false)
        let summary = UninstallSummary.make(records: [docker, zoom], stopped: ["Teams"], home: home)
        #expect(summary.movedBytes == 3 * gb)
        #expect(summary.sentence == "1 app moved to the Trash. Zoom was left alone: still running after Dustling asked it to quit. "
            + "Stopped before Teams, so it was left alone.")
        #expect(summary.apps.map(\.name) == ["Docker", "Zoom"])
        #expect(summary.apps[0].status == "2 items moved, 1 failed, 1 needs your Mac password")
        #expect(summary.apps[0].problems == [
            .init(path: "~/Library/Logs/Docker", reason: "failed: permission denied"),
            .init(path: "/Library/LaunchDaemons/com.docker.plist", reason: "needs your Mac password"),
        ])
        let limited = UninstallSummary.make(records: [docker], stopped: [], home: home, fullDiskAccess: false)
        #expect(limited.apps[0].status == "2 items moved, 1 failed, 1 needs Full Disk Access, then your Mac password")
        #expect(limited.apps[0].problems.last?.reason == "needs Full Disk Access, then your Mac password")
        #expect(summary.apps[0].canPutBack)
        #expect(summary.apps[1].status == "Left alone: still running after Dustling asked it to quit")
        #expect(summary.apps[1].problems.isEmpty)
        #expect(!summary.apps[1].canPutBack)
    }
}

extension UninstallerScreenTests {
    @Test func pathsDropTheFolderSlash() {
        let home = URL(filePath: "/Users/k")
        #expect(UninstallerScreen.path(URL(filePath: "/Users/k/Library/Caches/x", directoryHint: .isDirectory), home: home)
            == "~/Library/Caches/x")
        #expect(UninstallerScreen.path(URL(filePath: "/Applications/A.app/"), home: home) == "/Applications/A.app")
    }

    @Test func accessSkippedNoteIsPlural() {
        let confirm = ConfirmModel(
            plan: [], ready: true, note: nil, perApp: [per("A", items: 1, bytes: gb)], dataWarnings: [],
            runningApps: [], launchAgents: 0, adminItems: 0, adminNote: nil, totalBytes: gb, limitedNote: nil,
            accessSkipped: 3)
        #expect(ConfirmText.make(confirm).notes == ["3 items need Full Disk Access and stay where they are."])
    }
}
