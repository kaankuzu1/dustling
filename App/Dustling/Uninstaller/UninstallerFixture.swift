#if DEBUG
import DustlingAppModel
import DustlingCore
import Foundation

/// DEBUG only. `-DustlingUninstallerFixture list|detail|review|confirm|confirm-all|confirm-limited|removing|done`
/// shows the Uninstaller with the approved mockup's sample apps for screenshots. Nothing here reads or touches
/// the disk: the apps carry plain display paths that are never read (generated icons, no sizes or
/// signatures), and the model refuses to load, uninstall or put back anything while the fixture is on.
extension AppModels {
    static let fixtureArgument = "DustlingUninstallerFixture"

    func applyUninstallerFixtureFromLaunchArguments() {
        guard let state = UserDefaults.standard.string(forKey: Self.fixtureArgument) else { return }
        showUninstallerFixture(state)
    }

    func showUninstallerFixture(_ state: String) {
        uninstallerFixture = true
        AppIconView.usesFixtureIcons = true
        selection = .uninstaller
        let fixture = UninstallerFixtureData(home: homeDirectory)
        fixtureTrashAccess = state != "confirm-limited"
        uninstaller.canTakeOutOfTrash = fixtureTrashAccess ?? false
        let checked = state == "list" ? [] : [fixture.dockerData]
        // "confirm" shows the sheet for one app, "confirm-all" for every app (its list scrolls); the
        // others select the mockup's three.
        let selected = state == "confirm" ? [fixture.docker.url]
            : state == "confirm-all" ? fixture.apps.map(\.url) : fixture.apps.prefix(3).map(\.url)
        uninstaller.showFixture(
            apps: fixture.apps, leftovers: fixture.leftovers, running: [fixture.docker.url],
            selection: Set(selected), checked: checked, excluded: fixture.excluded)
        AppVersion.fixture = fixture.versions
        uninstallerFixtureConfirm = state.hasPrefix("confirm")
        uninstallerFixtureReview = state == "review"
        let plan = uninstaller.confirmation.plan
        switch state {
        case "removing":
            let progress = UninstallerModel.fixtureProgress(
                plan: plan, records: [fixture.docker.url: fixture.record(plan[0])], current: plan[1].app.url,
                doneInCurrent: 1)
            uninstaller.showFixtureRun(progress: progress, result: nil, uninstalling: true)
        case "done":
            let records = [
                fixture.record(plan[0]),
                fixture.record(plan[1], failing: 1),
                RunRecord(startedAt: .now, kind: .uninstall(appName: plan[2].app.displayName), entries: [
                    JournalEntry(originalPath: plan[2].app.url.path(percentEncoded: false), bytes: plan[2].app.bytes,
                                 outcome: .skipped(reason: UninstallerModel.stillRunningReason)),
                ], restorable: false),
            ]
            var progress = UninstallProgress(plan: plan)
            for (planned, record) in zip(plan, records) {
                progress.begin(planned.app.url)
                progress.finish(planned.app.url, record: record)
            }
            uninstaller.showFixtureRun(
                progress: progress, result: UninstallResult(records: records, stopped: []), uninstalling: false)
        default:
            uninstaller.showFixtureRun(progress: nil, result: nil, uninstalling: false)
        }
    }
}

/// The sample apps and leftovers from the approved mockup (`APPS` and `LEFT` in screens.html).
private struct UninstallerFixtureData {
    let home: URL
    let apps: [InstalledApp]
    let leftovers: [URL: [Leftover]]
    let versions: [URL: String]
    let excluded: [URL: String]
    let dockerData: URL
    var docker: InstalledApp { apps[0] }

    private static let gb = 1_000_000_000.0

    init(home: URL) {
        self.home = home
        // Plain display paths. Nothing reads them: the model refuses to load, uninstall or put back
        // while the fixture is on, and the icons are generated, never read from these bundles.
        let folder = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let day = 86_400.0
        func app(_ name: String, _ id: String?, _ gb: Double, daysAgo: Double, steam: String? = nil) -> InstalledApp {
            InstalledApp(
                url: folder.appending(path: "\(name).app", directoryHint: .isDirectory), displayName: name,
                bundleID: id, teamID: nil, executableName: nil, steamAppID: steam,
                bytes: UInt64(gb * Self.gb), lastUsed: Date.now.addingTimeInterval(-daysAgo * day))
        }
        let list = [
            app("Docker Desktop", "com.docker.docker", 2.08, daysAgo: 1),
            app("Android Studio", "com.google.android.studio", 2.61, daysAgo: 125),
            app("Microsoft Teams", "com.microsoft.teams2", 1.14, daysAgo: 155),
            app("Spotify", "com.spotify.client", 0.31, daysAgo: 0),
            app("Adobe Acrobat Reader", "com.adobe.Reader", 1.38, daysAgo: 215),
            app("Figma", "com.figma.Desktop", 0.48, daysAgo: 15),
            app("Zoom", "us.zoom.xos", 0.29, daysAgo: 22),
            app("Portal 2", nil, 0.04, daysAgo: 62, steam: "620"),
        ]
        apps = list
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        func lib(_ path: String) -> URL { library.appending(path: path) }
        func item(_ url: URL, _ kind: LeftoverKind, _ gb: Double, data: Bool = false, admin: Bool = false,
                  fuzzy: Bool = false, note: String? = nil) -> Leftover {
            Leftover(url: url, kind: kind, match: fuzzy ? .nameBased : .exact, mayContainUserData: data,
                     requiresAdmin: admin, bytes: UInt64(gb * Self.gb), note: note)
        }
        dockerData = lib("Containers/com.docker.docker")
        let androidLogs = lib("Logs/AndroidStudio2024.2")
        excluded = [androidLogs: "excluded in Settings"]
        leftovers = [
            list[0].url: [
                item(dockerData, .container, 11.46, data: true, note: "Your Docker images, containers and volumes"),
                item(lib("Group Containers/group.com.docker"), .groupContainer, 0.148),
                item(lib("Caches/com.docker.docker"), .caches, 0.084),
                item(lib("Application Support/Docker Desktop"), .applicationSupport, 0.036),
                item(lib("Preferences/com.docker.docker.plist"), .preferences, 0.000012),
                item(lib("Saved Application State/com.electron.dockerdesktop.savedState"), .savedState, 0.000028),
                item(URL(filePath: "/Library/PrivilegedHelperTools/com.docker.vmnetd"), .privilegedHelper, 0.0041,
                     admin: true),
                item(URL(filePath: "/Library/LaunchDaemons/com.docker.vmnetd.plist"), .launchDaemon, 0.000004,
                     admin: true),
                item(home.appending(path: ".docker"), .applicationSupport, 1.2, fuzzy: true),
            ],
            list[1].url: [
                item(lib("Application Support/Google/AndroidStudio2024.2"), .applicationSupport, 8.9, data: true),
                item(lib("Caches/Google/AndroidStudio2024.2"), .caches, 0.93),
                item(androidLogs, .logs, 0.012),
                item(lib("Preferences/com.google.android.studio.plist"), .preferences, 0.00002),
            ],
            list[2].url: [
                item(lib("Containers/com.microsoft.teams2"), .container, 1.6, data: true),
                item(lib("Group Containers/UBF8T346G9.com.microsoft.teams"), .groupContainer, 0.6),
                item(lib("Caches/com.microsoft.teams2"), .caches, 0.11),
            ],
            list[3].url: [
                item(lib("Caches/com.spotify.client"), .caches, 4.1),
                item(lib("Application Support/Spotify"), .applicationSupport, 0.12, data: true),
            ],
            list[4].url: [item(lib("Caches/com.adobe.Reader"), .caches, 0.38)],
            list[5].url: [item(lib("Application Support/Figma"), .applicationSupport, 1.19, data: true)],
            list[6].url: [item(lib("Application Support/zoom.us"), .applicationSupport, 0.16, data: true)],
            list[7].url: [
                item(lib("Application Support/Steam/steamapps/common/Portal 2"), .steamGameData, 11.9, data: true),
            ],
        ]
        versions = [
            list[0].url: "4.37.1", list[1].url: "2024.2.1", list[2].url: "24295.605", list[3].url: "1.2.50",
            list[4].url: "24.005", list[5].url: "124.6.5", list[6].url: "6.3.0",
        ]
    }

    /// A record as the uninstaller would write it: everything moved, helper items need admin, and
    /// `failing` leftovers failed.
    func record(_ planned: ConfirmModel.Planned, failing: Int = 0) -> RunRecord {
        var entries = [JournalEntry(
            originalPath: planned.app.url.path(percentEncoded: false), bytes: planned.app.bytes,
            outcome: .movedToTrash(trashedPath: "/fixture"))]
        var failed = 0
        for leftover in planned.leftovers where !leftover.requiresAdmin {
            let outcome: DeletionOutcome
            if failed < failing {
                failed += 1
                outcome = .failed(reason: "permission denied")
            } else {
                outcome = .movedToTrash(trashedPath: "/fixture")
            }
            entries.append(JournalEntry(
                originalPath: leftover.url.path(percentEncoded: false), bytes: leftover.bytes, outcome: outcome))
        }
        for leftover in planned.leftovers where leftover.requiresAdmin {
            entries.append(JournalEntry(
                originalPath: leftover.url.path(percentEncoded: false), bytes: leftover.bytes, outcome: .needsAdmin))
        }
        return RunRecord(
            startedAt: .now, kind: .uninstall(appName: planned.app.displayName), entries: entries, restorable: true)
    }
}
#endif
