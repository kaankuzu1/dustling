import AppKit
import DustlingAppModel
import DustlingCore
import Foundation
import Observation
import os

/// The models every window shares. Created once per app launch by `DustlingApp`.
@MainActor @Observable
final class AppModels {
    let health: HealthModel
    let storage: StorageModel
    /// Which junk places Dustling can open right now (onboarding and the limited-mode banner).
    let places: PlacesModel
    /// The onboarding window's step and the persisted "onboarding completed" flag.
    let onboarding = OnboardingState()
    /// The main window's selected destination. Shared so onboarding can send the user to a screen.
    var selection: Destination = .home
    /// The free space the user wants for a macOS update. Default 30 GB until Settings (Task 15) can
    /// change it; "Check update size" sets it from `softwareupdate`.
    var goal = UpdateGoal()
    /// The junk scan behind Home's hero and mosaic and the Junk scan screen.
    let junk: JunkScanModel
    /// The Trash: Home's Empty Trash button and the hatched "in Trash" cells.
    let trash: TrashModel
    /// Home's Uninstaller card (and the Uninstaller screen, Task 13).
    let uninstaller: UninstallerModel
    /// Home's Startup items card and the Startup items screen.
    let startup: StartupModel
    /// The History screen: every run, its log, and Restore.
    let history: HistoryModel
    /// "Check update size" next to the goal (Ruling R32).
    let updateCheck: UpdateSizeCheck
    /// The startup volume's name for the sidebar footer, e.g. "Macintosh HD".
    let volumeName: String

    /// False until a Full Disk Access probe result has been published. The sidebar hides the Full
    /// Disk Access light until then, so the pre-probe `.unknown` never flashes as a warning. A probe
    /// superseded by a newer one (onboarding polling at launch) doesn't count (Ruling R55).
    var hasProbedFullDiskAccess: Bool { health.hasPublishedStatus }

    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private let environment: SystemEnvironment
    @ObservationIgnored private let logger: RunLogger
    /// The junk categories by name and kind, in catalog order, for the Junk scan screen's tiles.
    @ObservationIgnored let junkCatalog: [JunkScreen.Entry]
    /// The categories the next junk scan may open (see `scanJunk()`).
    @ObservationIgnored private let scanCatalog: ScanCatalog
    /// What the last junk scan covered; places that opened since show as not scanned until a rescan.
    private(set) var lastScanScope: HomeScanScope?
    /// Home loads its numbers once per launch; "Scan again" reloads them.
    private(set) var homeLoaded = false
    /// The uninstaller looks inside other apps' containers, which asks for consent without Full
    /// Disk Access, so it only loads once access is on.
    @ObservationIgnored private var uninstallerLoaded = false
    /// True once an uninstaller load has finished counting leftovers (for Home's card).
    private(set) var uninstallerCounted = false
    /// True once startup items have been read at least once (for Home's card).
    private(set) var startupLoaded = false

    init(environment: SystemEnvironment = .current, commands: CommandRunning = ProcessCommandRunner()) {
        let journal = RunJournal(directory: environment.historyDirectory)
        let health = HealthModel(
            probe: { FullDiskAccessProbe(environment: environment).status() },
            clock: ContinuousClock(),
            lastRunSummary: { AppModels.latestRun(in: journal) })
        self.health = health
        let storage = StorageModel(commands: commands)
        self.storage = storage
        places = PlacesModel(environment: environment)
        volumeName = Self.readVolumeName()
        self.environment = environment

        let logger = RunLogger(directory: environment.logsDirectory)
        self.logger = logger
        junkCatalog = JunkCatalog.standard(environment).map {
            JunkScreen.Entry(id: $0.id, title: $0.title, selection: $0.selection)
        }
        let options = ScanOptions()
        let protectedPaths = options.protectedPaths(environment: environment)
        let runner = CleanupRunner(
            mover: TrashMover(backend: SystemTrashBackend(), protectedPaths: protectedPaths),
            journal: journal, logger: logger, sizer: DirectorySizer())
        let trash = TrashModel(
            makeInspector: { external in
                TrashInspector(
                    environment: environment, journal: journal, logger: logger, sizer: DirectorySizer(),
                    includeExternalVolumes: external)
            },
            journal: journal,
            onRunCompleted: {
                health.refreshLastRun()
                Task { await storage.refresh() }
            })
        self.trash = trash
        let scope = ScanCatalog()
        scanCatalog = scope
        junk = JunkScanModel(
            scanner: JunkScanner(environment: environment, runningBundleIDs: { AppModels.runningBundleIDs() }),
            runner: runner, journal: journal, environment: environment, options: options,
            categories: { scope.categories },
            onRunCompleted: {
                health.refreshLastRun()
                Task { await trash.refresh() }
                Task { await storage.refresh() }
            })
        // Unknown until the first probe: assume Put back can't work.
        junk.canTakeOutOfTrash = false
        let running = WorkspaceRunningApps()
        uninstaller = UninstallerModel(
            scout: AppScout(environment: environment),
            finder: LeftoverFinder(environment: environment, sizer: DirectorySizer(), commands: commands),
            uninstaller: Uninstaller(runner: runner, commands: commands, running: running, environment: environment),
            running: running, protectedPaths: protectedPaths, journal: journal, logger: logger,
            onRunCompleted: {
                // After every uninstall and every Put back.
                health.refreshLastRun()
                Task { await trash.refresh() }
                Task { await storage.refresh() }
            })
        // Owner names come from the installed apps, listed without measuring them.
        let startupScanner = StartupItemScanner(environment: environment, commands: commands, apps: [])
        startup = StartupModel(
            scanner: startupScanner,
            recorder: StartupChangeRecorder(scanner: startupScanner, journal: journal, logger: logger),
            apps: { AppScout(environment: environment, measuresSizes: false).discover() },
            remover: StartupRemover(runner: runner, commands: commands, environment: environment),
            onRunCompleted: {
                // After every switch and every remove.
                health.refreshLastRun()
                Task { await trash.refresh() }
            })
        history = HistoryModel(
            journal: journal, logger: logger, home: environment.home,
            onRunCompleted: {
                // After every Restore.
                health.refreshLastRun()
                Task { await trash.refresh() }
                Task { await storage.refresh() }
            })
        // Unknown until the first probe: assume Restore can't work.
        history.canTakeOutOfTrash = false
        updateCheck = UpdateSizeCheck(commands: commands)
        updateCheck.onMeasured = { [weak self] bytes in
            self?.goal = UpdateGoal(neededBytes: bytes, source: .measured(.now))
        }
        #if DEBUG
        // Screenshots of the goal-met state: `-DustlingDebugGoalBytes 1000000000`.
        // Read as text: launch arguments above Int32.max don't survive `integer(forKey:)`.
        if let text = UserDefaults.standard.string(forKey: "DustlingDebugGoalBytes"), let forced = Int64(text), forced > 0 {
            goal = UpdateGoal(neededBytes: forced)
        }
        applyUninstallerFixtureFromLaunchArguments()
        applyStartupHistoryFixtureFromLaunchArguments()
        #endif
    }

    // MARK: Home

    /// Loads Home's numbers the first time Home is shown, once the places check has run (a scan
    /// opens only places that read as open, so it never triggers a consent prompt).
    func loadHomeIfNeeded() {
        guard !homeLoaded, places.places != nil else { return }
        homeLoaded = true
        reloadHome()
    }

    /// "Scan again": the junk scan, the Trash, startup items and (with Full Disk Access) the apps.
    func reloadHome() {
        scanJunk()
        refreshTrash()
        Task {
            await startup.load(unjudged: unjudgedProgramFolders)
            startupLoaded = true
        }
        Task { await storage.refresh() }
        loadUninstallerIfAllowed(force: true)
    }

    /// Reads the startup items again: the Startup items screen, and when Full Disk Access changes
    /// which program folders may be looked at.
    func reloadStartup() {
        Task {
            await startup.load(unjudged: unjudgedProgramFolders)
            startupLoaded = true
        }
    }

    /// Shows a run's log file selected in Finder, or the logs folder when the file isn't there.
    func showLogInFinder(_ file: URL?) {
        if let file, FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            openLogFolder()
        }
    }

    /// "Open log folder". Says so if it can't.
    func openLogFolder() {
        let folder = logger.directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !NSWorkspace.shared.open(folder) {
            NSLog("Dustling: couldn't open the logs folder")
            let alert = NSAlert()
            alert.messageText = "The logs folder didn't open"
            alert.informativeText = "Dustling writes its logs to \(folder.path(percentEncoded: false))."
            alert.runModal()
        }
    }

    /// Starts a junk scan of the places that read as open right now.
    func scanJunk() {
        guard !junk.isBusy else { return }
        scanCatalog.categories = HomeMosaic.scannable(JunkCatalog.standard(environment), places: places.places)
        lastScanScope = HomeScanScope.make(places: places.places)
        junk.scan()
    }

    /// Scans again when places opened that the last scan couldn't cover (Full Disk Access arrived),
    /// unless a scan or cleanup is running or a cleanup summary is showing.
    func rescanIfPlacesOpened() {
        // Not under an open Review files sheet: a rescan would drop its list and the user's draft.
        guard homeLoaded, !junk.isReviewingFiles, let scope = lastScanScope,
              scope.shouldRescan(places: places.places, phase: homeFigures.phase) else { return }
        scanJunk()
    }

    /// Re-reads the Trash; other volumes' Trash folders only with Full Disk Access.
    func refreshTrash() {
        let granted = health.fullDiskAccess == .granted
        Task { await trash.refresh(fullDiskAccessGranted: granted) }
    }

    /// Folders whose programs aren't looked at when judging startup items: without Full Disk Access,
    /// the consent folders and other volumes (looking could raise a prompt).
    private var unjudgedProgramFolders: [URL] {
        ProgramPresence.unjudgedFolders(environment, fullDiskAccessGranted: health.fullDiskAccess == .granted)
    }

    /// Home's numbers from the shared models.
    var homeFigures: HomeFigures {
        let phase: HomeFigures.Phase
        switch junk.state {
        case .idle: phase = .notScanned
        case .scanning: phase = .scanning
        case .ready: phase = .ready
        case .moving: phase = .moving
        case .done: phase = .done
        }
        let reading: HomeFigures.TrashReading
        if let contents = trash.contents {
            reading = contents.issues.isEmpty
                ? .read(bytes: contents.size.bytes, externalSkipped: trash.externalVolumesSkipped)
                : .unreadable(movedSinceLastEmpty: trash.inTrashBytesSinceLastEmpty)
        } else {
            reading = .unknown
        }
        return HomeFigures.make(HomeFigures.Input(
            available: storage.info?.availableForImportantUsage, goal: goal, phase: phase,
            tiles: junk.categories, selectedBytes: junk.selectedBytesByCategory, trash: reading,
            places: places.places, scanScope: lastScanScope))
    }

    // MARK: Junk scan

    /// The Junk scan screen's tiles from the scan, the places check and the cleanup.
    var junkTiles: [JunkTile] {
        let phase: JunkScreen.Phase
        switch junk.state {
        case .idle: phase = .notScanned
        case .scanning: phase = .scanning
        case .ready: phase = .ready
        case .moving: phase = .moving
        case .done: phase = .done
        }
        return JunkScreen.tiles(JunkScreen.Input(
            catalog: junkCatalog, phase: phase, tiles: junk.categories, places: places.places, scope: lastScanScope,
            progress: junk.categoryProgress, outcomes: junk.categoryOutcomes))
    }

    /// Moves the selected junk to the Trash, leaving alone places that can't be read now (access may
    /// have been revoked since the scan). `confirmedLimited`: the user confirmed the limited-mode note.
    func cleanJunk(confirmedLimited: Bool = false) async {
        await junk.clean(skipping: cleanupSkip, confirmedLimited: confirmedLimited)
    }

    /// Places whose access isn't readable now, plus the container part of places that are only
    /// partly open.
    var cleanupSkip: CleanupSkip {
        let places = places.places ?? []
        let closed = Set(places.filter { $0.access != .readable }.map(\.id))
        let partly = Set(places.filter { $0.access == .readable && $0.lockedExpansions }.map(\.id))
        let folders = JunkCatalog.standard(environment)
            .filter { partly.contains($0.id) }
            .flatMap { $0.expansions.map(\.parent) }
        return CleanupSkip(categories: closed, folders: folders)
    }

    /// The home folder, for shortening paths on screen.
    var homeDirectory: URL { environment.home }

    /// Opens the log file the run was written to. Says so if it can't.
    func openLog(for record: RunRecord) {
        let file = logger.file(for: record.startedAt)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), NSWorkspace.shared.open(file) {
            return
        }
        NSLog("Dustling: couldn't open the log at \(file.path(percentEncoded: false))")
        let alert = NSAlert()
        alert.messageText = "The log didn't open"
        alert.informativeText = "Dustling writes its logs to \(logger.directory.path(percentEncoded: false)). "
            + "Open the file for \(record.startedAt.formatted(date: .abbreviated, time: .omitted)) from there."
        alert.runModal()
    }

    /// Opens the Trash in Finder, where the user can drag items back (Dustling can't read it without
    /// Full Disk Access).
    func showTrashInFinder() {
        let trash = environment.home.appending(path: ".Trash", directoryHint: .isDirectory)
        if !NSWorkspace.shared.open(trash) {
            NSLog("Dustling: couldn't open the Trash in Finder")
            let alert = NSAlert()
            alert.messageText = "The Trash didn't open"
            alert.informativeText = "Click the Trash in the Dock to open it in Finder."
            alert.runModal()
        }
    }

    /// The name of the app with this bundle ID, for "2 skipped because Mail is using them".
    nonisolated static func appName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The Uninstaller lists apps only with Full Disk Access (or the DEBUG screenshot fixture).
    var uninstallerAllowed: Bool {
        #if DEBUG
        if uninstallerFixture { return true }
        #endif
        return health.fullDiskAccess == .granted
    }

    #if DEBUG
    /// `-DustlingUninstallerFixture <state>`: fake apps for screenshots, never read from disk.
    var uninstallerFixture = false
    /// The fixture's stand-in for "Dustling can take things out of the Trash".
    var fixtureTrashAccess: Bool?
    /// The fixture opens the confirm sheet.
    var uninstallerFixtureConfirm = false
    /// The fixture opens Review all files.
    var uninstallerFixtureReview = false
    #endif

    /// Loads the apps once Full Disk Access is on; never without it (see `uninstallerLoaded`).
    func loadUninstallerIfAllowed(force: Bool = false) {
        guard health.fullDiskAccess == .granted, force || !uninstallerLoaded else { return }
        // Access is on now, even if refreshPlaces hasn't caught up yet.
        uninstaller.canReadAppData = true
        uninstaller.lockedFolders = []
        uninstallerLoaded = true
        Task {
            // A refused load must not leave the list stuck empty: the next chance tries again.
            guard await uninstaller.load() else {
                uninstallerLoaded = false
                return
            }
            uninstallerCounted = !uninstaller.isLoading
        }
    }

    private nonisolated static func runningBundleIDs() -> Set<String> {
        // The scanner flags caches of apps that are open right now.
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Runs the first probe and storage read, then re-checks whenever the app becomes active,
    /// because a rebuild or System Settings can change Full Disk Access while Dustling is open.
    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        Task {
            await health.refresh()
            // If this probe was superseded, the newer one publishes and the `.task(id:)` on the
            // Full Disk Access status refreshes the places then.
            await refreshPlaces()
        }
        Task { await storage.refresh() }
    }

    /// What a places check depends on. Views key `.task(id:)` on it, so places are checked after the
    /// first published probe even when that probe publishes `.unknown` (the status alone wouldn't change).
    struct FullDiskAccessKey: Hashable {
        let status: FullDiskAccessStatus
        let published: Bool
    }

    var fullDiskAccessKey: FullDiskAccessKey {
        FullDiskAccessKey(status: health.fullDiskAccess, published: health.hasPublishedStatus)
    }

    /// Re-checks which places are locked. Waits for the first Full Disk Access probe, because
    /// without access the check must not open folders that would prompt for consent.
    func refreshPlaces() async {
        // Without Full Disk Access macOS won't let Dustling take anything out of the Trash.
        junk.canTakeOutOfTrash = health.fullDiskAccess == .granted
        uninstaller.canTakeOutOfTrash = health.fullDiskAccess == .granted
        startup.canTakeOutOfTrash = health.fullDiskAccess == .granted
        history.canTakeOutOfTrash = health.fullDiskAccess == .granted
        // Without access, other apps' data and the consent folders are never touched by an uninstall.
        uninstaller.canReadAppData = health.fullDiskAccess == .granted
        uninstaller.lockedFolders = health.fullDiskAccess == .granted ? [] : unjudgedProgramFolders
            + [environment.userLibrary.appending(path: "Group Containers")]
        #if DEBUG
        if let fixtureTrashAccess { uninstaller.canTakeOutOfTrash = fixtureTrashAccess }
        #endif
        guard hasProbedFullDiskAccess else { return }
        await places.refresh(fullDiskAccessGranted: health.fullDiskAccess == .granted)
        // Selected totals and Review files leave out what can't be read now, like a cleanup does.
        junk.cleanupSkip = cleanupSkip
    }

    private func appBecameActive() {
        // Until the launch probe finishes it already covers this activation. Starting a second
        // probe now would supersede it, and the light would show before any result was published.
        guard hasProbedFullDiskAccess else { return }
        Task { await storage.refresh() }
        Task {
            // Probe first: places and the Trash must be checked with the access macOS gives now, or
            // a revoked grant could still open other volumes' Trash folders once.
            // A probe superseded by a newer one (onboarding polling) published nothing: that one's
            // status is the fresh one, and the `.task(id: fullDiskAccessKey)` refreshes places then.
            guard await health.refresh() else { return }
            await refreshPlaces()
            // The Trash may have been emptied or filled in Finder meanwhile.
            if homeLoaded { refreshTrash() }
        }
    }

    /// The newest run in the history journal, for the last-run health light. An unreadable journal
    /// is logged; the light then has no run to report on.
    private static func latestRun(in journal: RunJournal) -> RunRecord? {
        do {
            return try journal.all().max { $0.startedAt < $1.startedAt }
        } catch {
            NSLog("Dustling: couldn't read the run history for the health lights: \(error)")
            return nil
        }
    }

    private static func readVolumeName() -> String {
        do {
            let values = try URL(filePath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
            if let name = values.volumeLocalizedName, !name.isEmpty { return name }
        } catch {
            NSLog("Dustling: couldn't read the startup volume's name: \(error)")
        }
        return "Startup disk"
    }
}

/// The categories the next junk scan may open, set on the main actor right before `scan()` and read
/// by the scan model's catalog closure.
final class ScanCatalog: Sendable {
    private let lock = OSAllocatedUnfairLock<[JunkCategory]>(initialState: [])

    var categories: [JunkCategory] {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
