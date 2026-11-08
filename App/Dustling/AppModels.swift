import AppKit
import DustlingAppModel
import DustlingCore
import Foundation
import Observation

/// The models every window shares. Created once per app launch by `DustlingApp`.
@MainActor @Observable
final class AppModels {
    let health: HealthModel
    let storage: StorageModel
    /// The free space the user wants for a macOS update. Default 30 GB until Settings (Task 15) can change it.
    var goal = UpdateGoal()
    /// The startup volume's name for the sidebar footer, e.g. "Macintosh HD".
    let volumeName: String

    /// False until the first Full Disk Access probe has finished. The sidebar hides the Full Disk
    /// Access light until then, so the pre-probe `.unknown` never flashes as a warning.
    private(set) var hasProbedFullDiskAccess = false

    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(environment: SystemEnvironment = .current, commands: CommandRunning = ProcessCommandRunner()) {
        let journal = RunJournal(directory: environment.historyDirectory)
        health = HealthModel(
            probe: { FullDiskAccessProbe(environment: environment).status() },
            clock: ContinuousClock(),
            lastRunSummary: { AppModels.latestRun(in: journal) })
        storage = StorageModel(commands: commands)
        volumeName = Self.readVolumeName()
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
            hasProbedFullDiskAccess = true
        }
        Task { await storage.refresh() }
    }

    private func appBecameActive() {
        // Until the launch probe finishes it already covers this activation. Starting a second
        // probe now would supersede it, and the light would show before any result was published.
        guard hasProbedFullDiskAccess else { return }
        health.appBecameActive()
        Task { await storage.refresh() }
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
