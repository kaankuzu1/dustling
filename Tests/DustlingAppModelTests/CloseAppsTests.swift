import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// A quitter for tests: never touches real apps.
private final class ScriptedQuitter: AppQuitter, @unchecked Sendable {
    var quits: Set<String> = []
    var hangs: Set<String> = []
    private let lock = NSLock()
    private var asked: [String] = []
    var askedIDs: [String] { lock.withLock { asked } }

    func quit(_ app: InstalledApp) async -> Bool {
        let id = app.bundleID ?? ""
        lock.withLock { asked.append(id) }
        if hangs.contains(id) {
            try? await Task.sleep(for: .seconds(1000))
            return false
        }
        return quits.contains(id)
    }
}

private func app(_ id: String, _ name: String) -> RunningApp {
    RunningApp(bundleID: id, name: name, bundleURL: URL(filePath: "/Applications/\(name).app"))
}

@MainActor @Suite(.serialized)
struct CloseAppsTests {
    private func model(_ rig: ModelRig, running: Set<String>) -> JunkScanModel {
        let categories = rig.categories()
        let model = JunkScanModel(
            scanner: rig.scanner(running: running), runner: rig.runner(), journal: rig.journal,
            environment: rig.environment, options: rig.options, categories: { categories })
        model.canTakeOutOfTrash = true
        return model
    }

    private func scanned(_ model: JunkScanModel) async {
        model.scan()
        await model.awaitScan()
    }

    @Test func holdersAreRegularRunningAppsWithSelectedFiles() async throws {
        let rig = try ModelRig()
        let safari = try rig.file(rig.cachesDirectory.appending(path: "com.apple.Safari/blob"), bytes: 65536)
        try rig.file(rig.cachesDirectory.appending(path: "com.helper.agent/blob"), bytes: 4096)
        try rig.file(rig.cachesDirectory.appending(path: "plain.log"), bytes: 4096)
        let model = model(rig, running: ["com.apple.Safari", "com.helper.agent"])
        await scanned(model)

        // The helper agent isn't a regular app, so it isn't offered.
        let holders = model.openAppHolders(running: [app("com.apple.Safari", "Safari")])
        #expect(holders.map(\.name) == ["Safari"])
        #expect(holders[0].bytes == DirectorySizer().measure(safari.deletingLastPathComponent()).bytes)
        #expect(holders[0].itemCount == 1)

        // Unselected categories don't count.
        model.toggle(.userCaches)
        #expect(model.openAppHolders(running: [app("com.apple.Safari", "Safari")]).isEmpty)
    }

    @Test func titlesAndSummaryLine() {
        let one = [OpenAppHolder(bundleID: "s", name: "Safari", bundleURL: URL(filePath: "/A/Safari.app"), bytes: 1, itemCount: 1)]
        #expect(CloseApps.title(one) == "Close Safari to include its files?")
        let two = one + [OpenAppHolder(bundleID: "k", name: "Slack", bundleURL: URL(filePath: "/A/Slack.app"), bytes: 1, itemCount: 1)]
        #expect(CloseApps.title(two) == "Close 2 apps to include their files?")
        #expect(CloseApps.summaryLine([]) == nil)
        #expect(CloseApps.summaryLine(["Safari"]) == "Closed Safari before cleaning.")
        #expect(CloseApps.summaryLine(["Safari", "Slack"]) == "Closed Safari and Slack before cleaning.")
        #expect(CloseApps.summaryLine(["A", "B", "C"]) == "Closed A, B and C before cleaning.")
        #expect(CloseApps.note == "Dustling asks each app to quit, like pressing ⌘Q, so it can save your work and tabs. "
            + "It never forces an app to quit.")
    }

    @Test func quittingTracksEachAppAndTimesOut() async {
        let quitter = ScriptedQuitter()
        quitter.quits = ["a"]
        quitter.hangs = ["c"]
        let holders = ["a", "b", "c"].map { OpenAppHolder(bundleID: $0, name: $0.uppercased(), bundleURL: URL(filePath: "/A/\($0).app"), bytes: 1, itemCount: 1) }
        let run = CloseAppsRun(holders: holders)
        #expect(run.statuses == ["a": .waiting, "b": .waiting, "c": .waiting])
        #expect(!run.isFinished)

        await run.quitAll(using: quitter, timeout: .milliseconds(150))

        #expect(run.statuses == ["a": .closed, "b": .stillOpen, "c": .stillOpen])
        #expect(run.closedNames == ["A"])
        #expect(run.isFinished)
        #expect(Set(quitter.askedIDs) == ["a", "b", "c"])
        #expect(CloseApps.statusText(.closing) == "Closing…")
        #expect(CloseApps.statusText(.closed) == "Closed")
        #expect(CloseApps.statusText(.stillOpen) == "Still open, its files were skipped")
    }

    @Test func recheckFreesFilesOfClosedAppsAndCleanMovesThem() async throws {
        let rig = try ModelRig()
        let safari = try rig.file(rig.cachesDirectory.appending(path: "com.apple.Safari/blob"), bytes: 65536)
        let slack = try rig.file(rig.cachesDirectory.appending(path: "com.tinyspeck.slack/blob"), bytes: 8192)
        try rig.file(rig.cachesDirectory.appending(path: "plain.log"), bytes: 4096)
        let model = model(rig, running: ["com.apple.Safari", "com.tinyspeck.slack"])
        await scanned(model)
        let before = model.selectedBytes
        let promised = before + model.openAppHolders(running: [app("com.apple.Safari", "Safari"), app("com.tinyspeck.slack", "Slack")])
            .reduce(0) { $0 + $1.bytes }

        // Safari closed, Slack stayed open.
        model.recheckInUse(stillRunning: ["com.tinyspeck.slack"])
        let safariBytes = DirectorySizer().measure(safari.deletingLastPathComponent()).bytes
        #expect(model.selectedBytes == before + safariBytes)
        #expect(model.selectedBytes < promised)   // the sheet must say the figure changed

        let confirmed = model.selectedBytes
        await model.clean(closedApps: ["Safari"])
        guard case .done(let record) = model.state else { Issue.record("expected done"); return }
        #expect(record.bytesMovedToTrash == confirmed)
        #expect(!FileManager.default.fileExists(atPath: safari.path))
        #expect(FileManager.default.fileExists(atPath: slack.path))
        #expect(record.entries.contains { $0.outcome == .skipped(reason: "in use by com.tinyspeck.slack") })
        #expect(model.closedApps == ["Safari"])
        #expect(CloseApps.summaryLine(model.closedApps) == "Closed Safari before cleaning.")

        // A rescan forgets them.
        await scanned(model)
        #expect(model.closedApps.isEmpty)
    }
}
