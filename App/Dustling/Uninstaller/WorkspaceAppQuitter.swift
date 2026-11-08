import AppKit
import DustlingAppModel
import DustlingCore
import Foundation

/// Quits a running app before it is uninstalled: asks it with `NSRunningApplication.terminate()`, then
/// returns only once every instance has really terminated, or false after `timeout` (the model then
/// records the app as skipped, "still running", and moves on to the next one).
struct WorkspaceAppQuitter: AppQuitter {
    var timeout: Duration = .seconds(10)

    func quit(_ app: InstalledApp) async -> Bool {
        let targets = Set([app.url, app.linkTarget].compactMap { $0.map(Self.key) })
        let asked = await MainActor.run { Self.terminate(targets) }
        guard asked else { return true }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if await MainActor.run(body: { !Self.isRunning(targets) }) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await MainActor.run { !Self.isRunning(targets) }
    }

    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    @MainActor private static func instances(_ targets: Set<String>) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            guard let bundle = $0.bundleURL, !$0.isTerminated else { return false }
            return targets.contains(key(bundle))
        }
    }

    /// True when at least one instance was asked to quit.
    @MainActor private static func terminate(_ targets: Set<String>) -> Bool {
        let running = instances(targets)
        for app in running where !app.terminate() {
            NSLog("Dustling: \(app.localizedName ?? "an app") didn't accept the request to quit")
        }
        return !running.isEmpty
    }

    @MainActor private static func isRunning(_ targets: Set<String>) -> Bool { !instances(targets).isEmpty }
}
