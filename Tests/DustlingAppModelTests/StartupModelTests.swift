import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

@MainActor
struct StartupModelTests {
    private func makeModel(
        _ rig: ModelRig, commands: FakeCommands = FakeCommands(), onRunCompleted: @escaping @MainActor () -> Void = {}
    ) -> StartupModel {
        let scanner = rig.startupScanner(commands: commands)
        let recorder = StartupChangeRecorder(
            scanner: scanner, journal: rig.journal, logger: RunLogger(directory: rig.environment.logsDirectory))
        return StartupModel(scanner: scanner, recorder: recorder, onRunCompleted: onRunCompleted)
    }

    private func program(_ rig: ModelRig) throws -> String {
        try rig.file(rig.root.appending(path: "bin/tool"), bytes: 8).path
    }

    @Test func daemonsDisabledWithoutHelper() async throws {
        let rig = try ModelRig()
        let tool = try program(rig)
        try rig.writeLaunchPlist(rig.environment.systemLibrary.appending(path: "LaunchDaemons"), label: "com.x.daemon", program: tool)
        try rig.writeLaunchPlist(rig.environment.userLibrary.appending(path: "LaunchAgents"), label: "com.x.agent", program: tool)
        let model = makeModel(rig)
        await model.load()

        let daemons = try #require(model.groups.first { $0.kind == .daemons })
        let daemon = try #require(daemons.rows.first)
        #expect(daemon.chip == "Needs the cleanup helper")
        #expect(!daemon.canToggle)
        let agent = try #require(model.groups.first { $0.kind == .agents }?.rows.first)
        #expect(agent.chip == nil)
        #expect(agent.canToggle)
        // Login items can't be listed; the group is there and points to System Settings.
        let login = try #require(model.groups.first { $0.kind == .loginItems })
        #expect(login.total == 0)
    }

    @Test func loginItemRowPointsToSystemSettings() {
        let item = StartupItem(
            label: "Helper", scope: .loginItem, plistURL: nil, program: nil, ownerAppName: nil, isEnabled: true,
            managedInSystemSettingsOnly: true)
        let rig = try! ModelRig()
        let row = makeModel(rig).row(for: item)
        #expect(row.showsSystemSettingsLink)
        #expect(!row.canToggle)
        #expect(row.chip == nil)
    }

    @Test func orphanedItemDetected() async throws {
        let rig = try ModelRig()
        let tool = try program(rig)
        let agents = rig.environment.userLibrary.appending(path: "LaunchAgents")
        try rig.writeLaunchPlist(agents, label: "com.x.ok", program: tool)
        try rig.writeLaunchPlist(agents, label: "com.gone.agent", program: "/Applications/Gone.app/Contents/MacOS/gone")
        let model = makeModel(rig)
        await model.load()

        let banner = try #require(model.orphanBanner)
        #expect(banner.items.map(\.label) == ["com.gone.agent"])
        #expect(banner.message.contains("1 startup item"))
        let rows = try #require(model.groups.first { $0.kind == .agents }).rows
        #expect(rows.first { $0.item.label == "com.gone.agent" }?.isOrphaned == true)
        #expect(rows.first { $0.item.label == "com.x.ok" }?.isOrphaned == false)
    }

    @Test func noOrphansMeansNoBanner() async throws {
        let rig = try ModelRig()
        try rig.writeLaunchPlist(
            rig.environment.userLibrary.appending(path: "LaunchAgents"), label: "com.x.ok", program: try program(rig))
        let model = makeModel(rig)
        await model.load()
        #expect(model.orphanBanner == nil)
    }

    @Test func toggleIsRecordedAsTurnedOffNotSkipped() async throws {
        let rig = try ModelRig()
        let commands = FakeCommands()
        try rig.writeLaunchPlist(
            rig.environment.userLibrary.appending(path: "LaunchAgents"), label: "com.x.agent", program: try program(rig))
        let completed = Counter()
        let model = makeModel(rig, commands: commands, onRunCompleted: { completed.bump() })
        await model.load()
        let item = try #require(model.items.first)

        let record = try #require(await model.toggle(item))

        #expect(record.kind == .startupChange)
        let entry = try #require(record.entries.first)
        #expect(entry.outcome == .skipped(reason: "disabled"))
        #expect(OutcomePresentation.text(entry.outcome, in: record.kind) == "Turned off")
        #expect(model.lastChange == "Turned off com.x.agent")
        #expect(model.lastResult?.result == StartupScreen.ChangeResult(
            success: true, title: "Turned off tool.", message: nil))
        #expect(completed.value == 1)
        #expect(commands.calls.contains { $0.contains("disable") })
        #expect(try rig.journal.all().count == 1)
        // The same text means something else outside a startup run.
        #expect(OutcomePresentation.text(entry.outcome, in: .junkClean) == "Skipped: disabled")
    }

    @Test func countsAndFilter() async throws {
        let rig = try ModelRig()
        let tool = try program(rig)
        let agents = rig.environment.userLibrary.appending(path: "LaunchAgents")
        try rig.writeLaunchPlist(agents, label: "com.x.a", program: tool)
        try rig.writeLaunchPlist(agents, label: "com.x.b", program: tool)
        let model = makeModel(rig)
        await model.load()
        _ = await model.toggle(try #require(model.items.first { $0.label == "com.x.a" }))
        // The fake launchctl reports nothing disabled, so a rescan shows both on again; counts still add up.
        let group = try #require(model.groups.first { $0.kind == .agents })
        #expect(group.total == 2)
        #expect(group.countText == "\(group.onCount)/2")
        model.setFilter(.off, for: .agents)
        let off = try #require(model.groups.first { $0.kind == .agents })
        #expect(off.filter == .off)
        #expect(off.rows.allSatisfy { !$0.item.isEnabled })
        #expect(off.total == 2)
    }

    @Test func orphansAreJudgedOnlyForAbsolutePathsAndComputedOnceInLoad() async throws {
        let rig = try ModelRig()
        let agents = rig.environment.userLibrary.appending(path: "LaunchAgents")
        try rig.writeLaunchPlist(agents, label: "com.x.bare", program: "sometool")
        try rig.writeLaunchPlist(agents, label: "com.x.gone", program: "/nope/gone")
        let checks = Counter()
        let scanner = rig.startupScanner()
        let recorder = StartupChangeRecorder(
            scanner: scanner, journal: rig.journal, logger: RunLogger(directory: rig.environment.logsDirectory))
        let model = StartupModel(
            scanner: scanner, recorder: recorder, presence: { _ in checks.bump(); return .missing })
        await model.load()

        #expect(model.orphanBanner?.items.map(\.label) == ["com.x.gone"])
        let afterLoad = checks.value
        #expect(afterLoad == 1)   // the bare name was never checked
        for _ in 0..<5 { _ = model.groups; _ = model.orphanBanner }
        #expect(checks.value == afterLoad)
    }

    @Test func unreadableProgramIsNotAnOrphan() throws {
        try #require(getuid() != 0, "root can look anywhere")
        let rig = try ModelRig()
        let locked = rig.root.appending(path: "locked")
        try rig.file(locked.appending(path: "tool"), bytes: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false)) }
        let program = locked.appending(path: "tool").path(percentEncoded: false)
        #expect(ProgramPresence.check(program) == .unknown)
        #expect(!ProgramPresence.isOrphan(program, unjudged: [], presence: ProgramPresence.check))
        #expect(ProgramPresence.check(rig.root.appending(path: "nope/tool").path(percentEncoded: false)) == .missing)
        // A file used as a folder: ENOTDIR, gone.
        let file = try rig.file(rig.root.appending(path: "plain"), bytes: 1)
        #expect(ProgramPresence.check(file.appending(path: "tool").path(percentEncoded: false)) == .missing)
    }

    @Test func programsInConsentFoldersAreNeverLookedAt() async throws {
        let rig = try ModelRig()
        let agents = rig.environment.userLibrary.appending(path: "LaunchAgents")
        let downloads = rig.environment.home.appending(path: "Downloads")
        try rig.writeLaunchPlist(agents, label: "com.x.dl", program: downloads.appending(path: "gone").path(percentEncoded: false))
        try rig.writeLaunchPlist(agents, label: "com.x.vol", program: "/Volumes/Stick/gone")
        try rig.writeLaunchPlist(agents, label: "com.x.gone", program: "/nope/gone")
        let looked = Paths()
        let scanner = rig.startupScanner()
        let recorder = StartupChangeRecorder(
            scanner: scanner, journal: rig.journal, logger: RunLogger(directory: rig.environment.logsDirectory))
        let model = StartupModel(scanner: scanner, recorder: recorder, presence: { looked.add($0); return .missing })
        await model.load(unjudged: [downloads, URL(filePath: "/Volumes")])
        #expect(model.orphanBanner?.items.map(\.label) == ["com.x.gone"])
        #expect(looked.all == ["/nope/gone"])
    }
}

@MainActor
struct StartupModelScreenTests {
    private func makeModel(
        _ rig: ModelRig, commands: FakeCommands = FakeCommands(), apps: [InstalledApp] = [],
        listed: Paths? = nil, failing: Set<String> = [], onRunCompleted: @escaping @MainActor () -> Void = {}
    ) -> StartupModel {
        let scanner = rig.startupScanner(commands: commands)
        let recorder = StartupChangeRecorder(
            scanner: scanner, journal: rig.journal, logger: RunLogger(directory: rig.environment.logsDirectory))
        let remover = StartupRemover(runner: rig.runner(failing: failing), commands: commands, environment: rig.environment)
        return StartupModel(
            scanner: scanner, recorder: recorder,
            apps: { folders in
                listed?.add("list:" + folders.map { $0.lastPathComponent }.joined(separator: ","))
                return apps
            },
            remover: remover, onRunCompleted: onRunCompleted)
    }

    private var agents: (ModelRig) -> URL { { $0.environment.userLibrary.appending(path: "LaunchAgents") } }

    @Test func rowsShowTheOwningAppFromTheAppList() async throws {
        let rig = try ModelRig()
        let appURL = rig.environment.applicationDirectories[0].appending(path: "Tool.app", directoryHint: .isDirectory)
        let program = try rig.file(appURL.appending(path: "Contents/MacOS/tool"), bytes: 1)
        try rig.writeLaunchPlist(agents(rig), label: "com.tool.agent", program: program.path(percentEncoded: false))
        let app = InstalledApp(
            url: appURL, displayName: "Tool", bundleID: "com.tool", teamID: nil, executableName: "tool",
            steamAppID: nil, bytes: 0, lastUsed: nil)
        let model = makeModel(rig, apps: [app])
        await model.load()
        let row = try #require(model.groups.first { $0.kind == .agents }?.rows.first)
        #expect(row.owner == "Tool")
        #expect(row.ownerAppURL == appURL)
        #expect(row.name == "Tool")
        #expect(row.kindName == "Launch agent")
        #expect(row.badge == nil)
    }

    @Test func orphanRowsSayTheAppWasRemoved() async throws {
        let rig = try ModelRig()
        try rig.writeLaunchPlist(
            agents(rig), label: "com.gone.agent", program: "/Applications/Gone App.app/Contents/MacOS/gone")
        let model = makeModel(rig)
        await model.load()
        let row = try #require(model.groups.first { $0.kind == .agents }?.rows.first)
        #expect(row.isOrphaned)
        #expect(row.badge == .appNotFound)
        #expect(row.owner == "Removed app")
        #expect(model.orphanScreenBanner?.title == "Gone App was uninstalled, but its startup item still runs.")
    }

    @Test func kindFilterNarrowsTheGroups() async throws {
        let rig = try ModelRig()
        let tool = try rig.file(rig.root.appending(path: "bin/tool"), bytes: 1).path(percentEncoded: false)
        try rig.writeLaunchPlist(agents(rig), label: "com.x.agent", program: tool)
        try rig.writeLaunchPlist(rig.environment.systemLibrary.appending(path: "LaunchDaemons"), label: "com.x.d", program: tool)
        let model = makeModel(rig)
        await model.load()
        #expect(model.shownGroups.map(\.kind) == [.loginItems, .agents, .daemons])
        model.kindFilter = .daemons
        #expect(model.shownGroups.map(\.kind) == [.daemons])
        let daemon = try #require(model.shownGroups.first?.rows.first)
        #expect(daemon.badge == .helper)
        #expect(!daemon.canToggle)
        #expect(!model.canRemove(daemon.item))
    }

    @Test func removeUnloadsTheAgentMovesItToTheTrashAndRecordsIt() async throws {
        let rig = try ModelRig()
        let commands = FakeCommands()
        let tool = try rig.file(rig.root.appending(path: "bin/tool"), bytes: 1).path(percentEncoded: false)
        let plist = try rig.writeLaunchPlist(agents(rig), label: "com.x.agent", program: tool)
        let completed = Counter()
        let model = makeModel(rig, commands: commands, onRunCompleted: { completed.bump() })
        model.canTakeOutOfTrash = true
        await model.load()
        let item = try #require(model.items.first)
        #expect(model.canRemove(item))
        let itemPlist = try #require(item.plistURL).path(percentEncoded: false)

        let record = try #require(await model.remove(item))

        #expect(record.kind == .startupChange)
        #expect(record.restorable)
        guard case .movedToTrash = record.entries.first?.outcome else {
            Issue.record("expected a move, got \(record.entries)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: plist.path(percentEncoded: false)))
        #expect(commands.calls.contains { $0.contains("bootout") && $0.contains(itemPlist) })
        #expect(completed.value == 1)
        #expect(model.items.isEmpty)
        #expect(model.lastResult?.result.title == "Moved tool to the Trash.")
        #expect(model.lastResult?.record.id == record.id)
        #expect(try rig.journal.all().map(\.id) == [record.id])
    }

    @Test func aFailedMoveAfterStoppingSaysItComesBackAtLogin() async throws {
        let rig = try ModelRig()
        let tool = try rig.file(rig.root.appending(path: "bin/tool"), bytes: 1).path(percentEncoded: false)
        let plist = try rig.writeLaunchPlist(agents(rig), label: "com.x.agent", program: tool)
        let model = makeModel(rig, failing: ["com.x.agent.plist"])
        await model.load()
        let item = try #require(model.items.first)
        let record = try #require(await model.remove(item))
        #expect(!record.restorable)
        #expect(FileManager.default.fileExists(atPath: plist.path(percentEncoded: false)))
        let result = try #require(model.lastResult?.result)
        #expect(!result.success)
        #expect(result.title == "tool wasn't moved.")
        #expect(result.message == "disk exploded. It was stopped but will start again at your next login.")
    }

    @Test func appsAreListedWithTheUnjudgedFoldersAndReusedAfterAChange() async throws {
        let rig = try ModelRig()
        let tool = try rig.file(rig.root.appending(path: "bin/tool"), bytes: 1).path(percentEncoded: false)
        try rig.writeLaunchPlist(agents(rig), label: "com.x.agent", program: tool)
        let listed = Paths()
        let model = makeModel(rig, listed: listed)
        let documents = rig.environment.home.appending(path: "Documents")
        await model.load(unjudged: [documents])
        #expect(listed.all == ["list:Documents"])
        let item = try #require(model.items.first)
        _ = await model.toggle(item)
        #expect(listed.all == ["list:Documents"])   // the reload reused the list
        await model.load(unjudged: [])
        #expect(listed.all == ["list:Documents", "list:"])   // other folders: listed again
    }

    @Test func removeIsRefusedForItemsOutsideTheUsersLaunchAgents() async throws {
        let rig = try ModelRig()
        let tool = try rig.file(rig.root.appending(path: "bin/tool"), bytes: 1).path(percentEncoded: false)
        let plist = try rig.writeLaunchPlist(
            rig.environment.systemLibrary.appending(path: "LaunchAgents"), label: "com.x.sys", program: tool)
        let model = makeModel(rig)
        await model.load()
        let item = try #require(model.items.first)
        #expect(!model.canRemove(item))
        #expect(await model.remove(item) == nil)
        #expect(FileManager.default.fileExists(atPath: plist.path(percentEncoded: false)))
        #expect(try rig.journal.all().isEmpty)
    }

    @Test func toggleFailureIsShownNotSilent() async throws {
        let rig = try ModelRig()
        let tool = try rig.file(rig.root.appending(path: "bin/tool"), bytes: 1).path(percentEncoded: false)
        try rig.writeLaunchPlist(rig.environment.systemLibrary.appending(path: "LaunchDaemons"), label: "com.x.d", program: tool)
        let model = makeModel(rig)
        await model.load()
        let daemon = try #require(model.items.first)
        let record = try #require(await model.toggle(daemon))
        #expect(record.entries.first?.outcome == .needsAdmin)
        #expect(model.lastResult?.result.success == false)
        #expect(model.lastResult?.result.message == "Needs the cleanup helper (coming in a later version)")
        model.dismissResult()
        #expect(model.lastResult == nil)
    }

    #if DEBUG
    @Test func fixtureNeverTouchesTheDisk() async throws {
        let rig = try ModelRig()
        let commands = FakeCommands()
        let model = makeModel(rig, commands: commands)
        let fake = StartupItem(
            label: "com.fixture.agent", scope: .userAgent,
            plistURL: rig.root.appending(path: "nowhere/com.fixture.agent.plist"), program: "/nowhere/tool",
            ownerAppName: "Fixture", isEnabled: true, managedInSystemSettingsOnly: false)
        model.showFixture(items: [fake], orphanIDs: [fake.id])
        #expect(model.items == [fake])
        #expect(model.orphanScreenBanner != nil)
        await model.load()
        #expect(model.items == [fake])
        #expect(await model.toggle(fake) == nil)
        #expect(await model.remove(fake) == nil)
        #expect(commands.calls.isEmpty)
        #expect(try rig.journal.all().isEmpty)
    }
    #endif
}

private final class Paths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.withLock { paths.append(path) } }
    var all: [String] { lock.withLock { paths } }
}
