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
    /// Home's Startup items card (and the Startup items screen, Task 14).
    let startup: StartupModel
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
        let running = WorkspaceRunningApps()
        uninstaller = UninstallerModel(
            scout: AppScout(environment: environment),
            finder: LeftoverFinder(environment: environment, sizer: DirectorySizer(), commands: commands),
            uninstaller: Uninstaller(runner: runner, commands: commands, running: running, environment: environment),
            running: running, protectedPaths: protectedPaths, journal: journal, logger: logger,
            onRunCompleted: { health.refreshLastRun() })
        // The owner app names come with the Startup items screen (Task 14); Home only counts items.
        let startupScanner = StartupItemScanner(environment: environment, commands: commands, apps: [])
        startup = StartupModel(
            scanner: startupScanner,
            recorder: StartupChangeRecorder(scanner: startupScanner, journal: journal, logger: logger),
            onRunCompleted: { health.refreshLastRun() })
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
        guard homeLoaded, let scope = lastScanScope, scope.isOutgrown(by: places.places) else { return }
        switch junk.state {
        case .ready, .idle, .problem: scanJunk()
        case .scanning, .moving, .done: break
        }
    }

    /// Re-reads the Trash; other volumes' Trash folders only with Full Disk Access.
    func refreshTrash() {
        let granted = health.fullDiskAccess == .granted
        Task { await trash.refresh(fullDiskAccessGranted: granted) }
    }

    /// Folders whose programs aren't looked at when judging startup items: without Full Disk Access,
    /// the consent folders and other volumes (looking could raise a prompt).
    private var unjudgedProgramFolders: [URL] {
        guard health.fullDiskAccess != .granted else { return [] }
        return PlaceAccessChecker.consentFolders(environment) + [URL(filePath: "/Volumes")]
    }

    /// Home's numbers from the shared models.
    var homeFigures: HomeFigures {
        let phase: HomeFigures.Phase
        switch junk.state {
        case .idle: phase = .notScanned
        case .scanning: phase = .scanning
        case .ready, .problem: phase = .ready
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
            tiles: junk.categories, selectedBytes: junk.selectedBytes, trash: reading,
            places: places.places, scanScope: lastScanScope))
    }

    /// Loads the apps once Full Disk Access is on; never without it (see `uninstallerLoaded`).
    func loadUninstallerIfAllowed(force: Bool = false) {
        guard health.fullDiskAccess == .granted, force || !uninstallerLoaded else { return }
        uninstallerLoaded = true
        Task {
            await uninstaller.load()
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
        guard hasProbedFullDiskAccess else { return }
        await places.refresh(fullDiskAccessGranted: health.fullDiskAccess == .granted)
    }

    private func appBecameActive() {
        // Until the launch probe finishes it already covers this activation. Starting a second
        // probe now would supersede it, and the light would show before any result was published.
        guard hasProbedFullDiskAccess else { return }
        health.appBecameActive()
        Task { await storage.refresh() }
        // The Trash may have been emptied or filled in Finder meanwhile.
        if homeLoaded { refreshTrash() }
        Task { await refreshPlaces() }
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
