import DustlingCore
import Foundation
import Observation

public enum StartupGroupKind: String, CaseIterable, Sendable {
    case loginItems, agents, daemons

    public var title: String {
        switch self {
        case .loginItems: "Login items"
        case .agents: "Agents"
        case .daemons: "Daemons"
        }
    }

    static func of(_ scope: StartupScope) -> StartupGroupKind {
        switch scope {
        case .loginItem: .loginItems
        case .userAgent, .systemAgent: .agents
        case .systemDaemon: .daemons
        }
    }
}

public enum StartupFilter: Sendable, CaseIterable {
    case all, on, off
}

public struct StartupRow: Identifiable, Equatable, Sendable {
    public let item: StartupItem
    /// "Needs the cleanup helper" for system items; nil otherwise.
    public let chip: String?
    /// False when the switch is shown disabled.
    public let canToggle: Bool
    /// Login items are changed only in System Settings; the row shows that link.
    public let showsSystemSettingsLink: Bool
    public let isOrphaned: Bool
    /// What people would call it (`StartupScreen.displayName`).
    public let name: String
    /// "Launch agent", "Launch daemon" or "Login item".
    public let kindName: String
    /// The app it belongs to, "Removed app" for an orphan, or nil when unknown.
    public let owner: String?
    /// The owning app's bundle, for its icon.
    public let ownerAppURL: URL?
    public let badge: StartupScreen.Badge?
    public var id: String { item.id }
}

/// What the last switch or remove did, for the banner at the top of the screen.
public struct StartupChange: Equatable, Sendable {
    public let record: RunRecord
    public let result: StartupScreen.ChangeResult
    public let action: StartupScreen.Action
    public let itemName: String

    public init(record: RunRecord, result: StartupScreen.ChangeResult, action: StartupScreen.Action, itemName: String) {
        self.record = record
        self.result = result
        self.action = action
        self.itemName = itemName
    }
}

/// Removes a user launch agent: unloads it, then moves its plist to the Trash through the
/// `CleanupRunner` (kind `.startupChange`), so it is journaled, logged and can be put back. Only
/// items in `~/Library/LaunchAgents` qualify; everything else needs the helper.
public struct StartupRemover: Sendable {
    private let runner: CleanupRunner
    private let commands: any CommandRunning
    private let environment: SystemEnvironment

    public init(runner: CleanupRunner, commands: any CommandRunning, environment: SystemEnvironment) {
        self.runner = runner
        self.commands = commands
        self.environment = environment
    }

    private var agentsDirectory: URL {
        environment.userLibrary.appending(path: "LaunchAgents", directoryHint: .isDirectory)
    }

    public func canRemove(_ item: StartupItem) -> Bool {
        guard item.scope == .userAgent, let plist = item.plistURL else { return false }
        let parent = plist.deletingLastPathComponent().standardizedFileURL.pathComponents
        return parent == agentsDirectory.standardizedFileURL.pathComponents
    }

    /// What a remove did: the saved record, and whether the agent was stopped (booted out) first.
    public struct Removal: Sendable {
        public let record: RunRecord
        /// launchctl stopped a loaded agent. If the move then failed, it starts again at next login.
        public let stopped: Bool
    }

    /// nil when the item doesn't qualify (nothing is touched or recorded).
    public func remove(_ item: StartupItem) async -> Removal? {
        guard canRemove(item), let plist = item.plistURL else { return nil }
        var extra: [JournalEntry] = []
        var stopped = false
        // Unload first, but only what the guard lets the runner move.
        if runner.protectedPaths.verdict(for: plist, allowedRoots: [agentsDirectory]) == .allowed {
            switch unload(plist) {
            case .stopped: stopped = true
            case .notLoaded: break
            case .failed(let entry): extra.append(entry)
            }
        }
        let record = await runner.run(
            [plist], kind: .startupChange, allowedRoots: [agentsDirectory], extraEntries: extra, onItem: { _, _ in })
        return Removal(record: record, stopped: stopped)
    }

    private enum Unload {
        case stopped, notLoaded
        case failed(JournalEntry)
    }

    private func unload(_ plist: URL) -> Unload {
        let path = plist.path(percentEncoded: false)
        func failure(_ reason: String) -> Unload {
            .failed(JournalEntry(originalPath: path, bytes: 0, outcome: .failed(reason: "could not unload: \(reason)")))
        }
        do {
            let result = try commands.run("/bin/launchctl", ["bootout", "gui/\(environment.userID)", path])
            if result.status == 0 { return .stopped }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let notLoaded = ["No such process", "Could not find specified service"]
            if notLoaded.contains(where: { stderr.contains($0) }) { return .notLoaded }
            return failure(stderr)
        } catch {
            return failure(error.localizedDescription)
        }
    }
}

public struct StartupGroup: Identifiable, Equatable, Sendable {
    public let kind: StartupGroupKind
    /// The rows that pass the group's filter.
    public let rows: [StartupRow]
    public let onCount: Int
    public let total: Int
    public let filter: StartupFilter
    public var id: StartupGroupKind { kind }
    public var title: String { kind.title }
    /// "3/5".
    public var countText: String { "\(onCount)/\(total)" }
}

public struct OrphanBanner: Equatable, Sendable {
    public let items: [StartupItem]
    public let message: String
}

/// Drives the Startup items screen: login items, agents and daemons with on/off switches.
@MainActor @Observable
public final class StartupModel {
    public static let helperChip = "Needs the cleanup helper"

    public private(set) var items: [StartupItem] = []
    public private(set) var issues: [ScanIssue] = []
    public private(set) var isLoading = false
    /// What the last switch did, in plain words ("Turned off X"); nil before any.
    public private(set) var lastChange: String?
    /// The last switch or remove, for the screen's result banner. Cleared by `dismissResult()`.
    public private(set) var lastResult: StartupChange?
    /// The item being changed right now (its row shows a spinner).
    public private(set) var busyItemID: String?
    /// Computed once per `load()` so reading `groups` never touches the disk.
    public private(set) var orphanBanner: OrphanBanner?
    @ObservationIgnored private var orphanIDs: Set<String> = []
    public private(set) var filters: [StartupGroupKind: StartupFilter] = [:]
    /// The toolbar filter (All, Login items, Agents, Daemons).
    public var kindFilter: StartupScreen.Filter = .all
    /// False without Full Disk Access: macOS then won't let Dustling take a removed item out of the
    /// Trash, so the remove confirmation says so.
    public var canTakeOutOfTrash = false
    /// The installed apps from the last load, to name the app each item belongs to.
    @ObservationIgnored private var apps: [InstalledApp] = []
    /// Owners worked out in `load()` (by item id), so reading `groups` never touches the disk.
    @ObservationIgnored private var owners: [String: StartupScreen.Owner] = [:]

    @ObservationIgnored private let scanner: StartupItemScanner
    @ObservationIgnored private let recorder: StartupChangeRecorder
    @ObservationIgnored private let presence: @Sendable (String) -> ProgramPresence
    /// Lists the installed apps, leaving out any linked into the folders it is given.
    @ObservationIgnored private let listApps: @Sendable ([URL]) -> [InstalledApp]
    @ObservationIgnored private let remover: StartupRemover?
    @ObservationIgnored private let onRunCompleted: @MainActor () -> Void
    @ObservationIgnored private var generation = 0
    /// The folders the last `load` left unjudged, reused by the reload after a change.
    @ObservationIgnored private var lastUnjudged: [URL] = []
    /// The folders the cached app list was made with; a different set lists the apps again.
    @ObservationIgnored private var lastAppsUnjudged: [URL]?

    private func sameFolders(_ folders: [URL]) -> Bool {
        lastAppsUnjudged.map { Set($0.map(\.standardizedFileURL)) == Set(folders.map(\.standardizedFileURL)) } ?? false
    }
    #if DEBUG
    /// DEBUG screenshots: sample items that never came from or go to the disk.
    @ObservationIgnored public private(set) var isFixture = false
    #endif

    public init(
        scanner: StartupItemScanner, recorder: StartupChangeRecorder,
        presence: @escaping @Sendable (String) -> ProgramPresence = ProgramPresence.check,
        apps: @escaping @Sendable ([URL]) -> [InstalledApp] = { _ in [] },
        remover: StartupRemover? = nil,
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.scanner = scanner
        self.recorder = recorder
        self.presence = presence
        self.listApps = apps
        self.remover = remover
        self.onRunCompleted = onRunCompleted
    }

    private var fixtureOn: Bool {
        #if DEBUG
        return isFixture
        #else
        return false
        #endif
    }

    /// Reads the startup items and judges which point to a program that is gone. Programs under
    /// `unjudged` (folders that ask for consent without Full Disk Access, and other volumes) are never
    /// looked at, so loading can't raise a prompt; they are simply not called orphans.
    public func load(unjudged: [URL] = []) async {
        await load(unjudged: unjudged, reusingApps: false)
    }

    /// After a switch or a remove the installed apps haven't changed: the last list is reused.
    private func load(unjudged: [URL], reusingApps: Bool) async {
        guard !fixtureOn else { return }
        lastUnjudged = unjudged
        generation += 1
        let mine = generation
        isLoading = true
        let scanner = self.scanner, presence = self.presence, listApps = self.listApps
        let cached: [InstalledApp]? = reusingApps && sameFolders(unjudged) ? apps : nil
        lastAppsUnjudged = unjudged
        let found = await Blocking.run { () -> Loaded in
            let scanned = scanner.scanWithIssues()
            let orphans = scanned.items.filter {
                ProgramPresence.isOrphan($0.program, unjudged: unjudged, presence: presence)
            }
            let apps = cached ?? listApps(unjudged)
            var owners: [String: StartupScreen.Owner] = [:]
            for item in scanned.items {
                // An app bundle is looked at only outside the unjudged folders, like orphans.
                let owner = StartupScreen.owner(of: item, apps: apps) { path in
                    !Self.isInside(path, unjudged) && presence(path) == .present
                }
                if let owner { owners[item.id] = owner }
            }
            return Loaded(items: scanned.items, issues: scanned.issues, orphans: orphans, apps: apps, owners: owners)
        }
        guard mine == generation, !fixtureOn else { return }
        isLoading = false
        apply(items: found.items, issues: found.issues, orphans: found.orphans, owners: found.owners)
        apps = found.apps
    }

    private struct Loaded: Sendable {
        let items: [StartupItem]
        let issues: [ScanIssue]
        let orphans: [StartupItem]
        let apps: [InstalledApp]
        let owners: [String: StartupScreen.Owner]
    }

    private nonisolated static func isInside(_ path: String, _ folders: [URL]) -> Bool {
        let parts = URL(filePath: path).standardizedFileURL.pathComponents
        return folders.contains { folder in
            let prefix = folder.standardizedFileURL.pathComponents
            return parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
        }
    }

    private func apply(
        items: [StartupItem], issues: [ScanIssue], orphans: [StartupItem], owners: [String: StartupScreen.Owner]
    ) {
        self.items = items
        self.issues = issues
        self.owners = owners
        orphanIDs = Set(orphans.map(\.id))
        if orphans.isEmpty {
            orphanBanner = nil
        } else {
            let one = orphans.count == 1
            orphanBanner = OrphanBanner(
                items: orphans,
                message: "\(orphans.count) startup \(one ? "item" : "items") point to an app or file that is gone. Turning \(one ? "it" : "them") off is safe.")
        }
    }

    public func setFilter(_ filter: StartupFilter, for kind: StartupGroupKind) {
        filters[kind] = filter
    }

    public var groups: [StartupGroup] {
        StartupGroupKind.allCases.map { kind in
            let all = items.filter { StartupGroupKind.of($0.scope) == kind }
            let filter = filters[kind] ?? .all
            let shown = all.filter {
                switch filter {
                case .all: true
                case .on: $0.isEnabled
                case .off: !$0.isEnabled
                }
            }
            return StartupGroup(
                kind: kind, rows: shown.map(row(for:)), onCount: all.filter(\.isEnabled).count,
                total: all.count, filter: filter)
        }
    }

    /// The groups the toolbar filter shows.
    public var shownGroups: [StartupGroup] {
        groups.filter { kindFilter.shows($0.kind) }
    }

    /// The orphan banner's wording, or nil when nothing is orphaned.
    public var orphanScreenBanner: StartupScreen.OrphanBannerText? {
        StartupScreen.orphanBanner(orphanBanner?.items ?? [], canChange: { [self] in canRemove($0) })
    }

    func row(for item: StartupItem) -> StartupRow {
        let needsHelper = item.scope == .systemDaemon || item.scope == .systemAgent
        let loginOnly = item.scope == .loginItem || item.managedInSystemSettingsOnly
        let orphaned = orphanIDs.contains(item.id)
        let owner = owners[item.id] ?? item.ownerAppName.map { StartupScreen.Owner(name: $0, appURL: nil) }
        return StartupRow(
            item: item, chip: needsHelper ? Self.helperChip : nil,
            canToggle: !needsHelper && !loginOnly, showsSystemSettingsLink: loginOnly,
            isOrphaned: orphaned, name: StartupScreen.displayName(item), kindName: StartupScreen.kindName(item.scope),
            owner: orphaned ? "Removed app" : owner?.name, ownerAppURL: orphaned ? nil : owner?.appURL,
            badge: StartupScreen.badge(scope: item.scope, orphaned: orphaned, systemSettingsOnly: loginOnly))
    }

    /// Whether Dustling can remove the item itself (a user launch agent in ~/Library/LaunchAgents).
    public func canRemove(_ item: StartupItem) -> Bool {
        remover?.canRemove(item) ?? false
    }

    /// Turns `item` on or off (the opposite of how it is now) and records it in History. The engine
    /// decides whether it can: a system item comes back `Needs the cleanup helper`. Nil when refused
    /// (another change is running, or the DEBUG fixture is on): nothing was touched.
    @discardableResult
    public func toggle(_ item: StartupItem) async -> RunRecord? {
        guard !fixtureOn, busyItemID == nil else { return nil }
        busyItemID = item.id
        let recorder = self.recorder
        let target = !item.isEnabled
        let record = await Blocking.run { recorder.setEnabled(item, target) }
        let name = StartupScreen.displayName(item)
        if let entry = record.entries.first {
            let what = OutcomePresentation.text(entry.outcome, in: record.kind)
            lastChange = OutcomePresentation.isSuccessfulToggle(entry.outcome, in: record.kind)
                ? "\(what) \(item.label)" : "\(item.label): \(what)"
        }
        lastResult = StartupChange(
            record: record, result: StartupScreen.changeResult(record, name: name, action: .toggle),
            action: .toggle, itemName: name)
        await load(unjudged: lastUnjudged, reusingApps: true)
        busyItemID = nil
        onRunCompleted()
        return record
    }

    /// Unloads a user launch agent and moves its plist to the Trash (journaled as `.startupChange`).
    /// Nil when refused: the item doesn't qualify, another change is running, or the fixture is on.
    @discardableResult
    public func remove(_ item: StartupItem) async -> RunRecord? {
        guard !fixtureOn, busyItemID == nil, let remover, remover.canRemove(item) else { return nil }
        busyItemID = item.id
        guard let removal = await remover.remove(item) else {
            busyItemID = nil
            return nil
        }
        let record = removal.record
        let name = StartupScreen.displayName(item)
        lastResult = StartupChange(
            record: record,
            result: StartupScreen.changeResult(record, name: name, action: .remove, stoppedFirst: removal.stopped),
            action: .remove, itemName: name)
        await load(unjudged: lastUnjudged, reusingApps: true)
        busyItemID = nil
        onRunCompleted()
        return record
    }

    public func dismissResult() {
        lastResult = nil
    }

    #if DEBUG
    /// DEBUG screenshots only: shows `items` as if loaded. While on, `load`, `toggle` and `remove`
    /// all refuse, so nothing is read from or written to the disk.
    public func showFixture(items: [StartupItem], orphanIDs: Set<String>, owners: [String: String] = [:]) {
        isFixture = true
        isLoading = false
        canTakeOutOfTrash = true
        let orphans = items.filter { orphanIDs.contains($0.id) }
        apply(
            items: items, issues: [], orphans: orphans,
            owners: owners.mapValues { StartupScreen.Owner(name: $0, appURL: nil) })
    }

    /// DEBUG screenshots only: the result banner of a change that never ran.
    public func showFixtureResult(_ change: StartupChange?) {
        lastResult = change
    }
    #endif
}

/// Whether a startup item's program is still on disk.
public enum ProgramPresence: Equatable, Sendable {
    case present
    /// `lstat` said ENOENT or ENOTDIR: the program is gone.
    case missing
    /// It couldn't be looked at (EPERM, EACCES, …). Never counted as gone.
    case unknown

    /// Folders whose programs aren't looked at when judging startup items without Full Disk Access:
    /// the consent folders, iCloud Drive (`~/Library/Mobile Documents`) and other volumes. Looking
    /// there could raise a prompt. With access, everything is judged.
    public static func unjudgedFolders(_ environment: SystemEnvironment, fullDiskAccessGranted: Bool) -> [URL] {
        guard !fullDiskAccessGranted else { return [] }
        return PlaceAccessChecker.consentFolders(environment)
            + [environment.userLibrary.appending(path: "Mobile Documents"), URL(filePath: "/Volumes")]
    }

    public static func check(_ path: String) -> ProgramPresence {
        var info = stat()
        if lstat(path, &info) == 0 { return .present }
        switch errno {
        case ENOENT, ENOTDIR: return .missing
        default: return .unknown
        }
    }

    /// Only an absolute program path can be judged (a bare name is looked up on PATH at launch), and
    /// only outside `unjudged`. Orphaned only when the program is known to be missing.
    public static func isOrphan(
        _ program: String?, unjudged: [URL], presence: (String) -> ProgramPresence
    ) -> Bool {
        guard let program, program.hasPrefix("/") else { return false }
        let path = URL(filePath: program).standardizedFileURL.pathComponents
        for folder in unjudged {
            let prefix = folder.standardizedFileURL.pathComponents
            if path.count >= prefix.count && Array(path.prefix(prefix.count)) == prefix { return false }
        }
        return presence(program) == .missing
    }
}
