import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// A quitter for tests: never touches real apps.
private final class ScriptedQuitter: AppQuitter, @unchecked Sendable {
    var quits: Set<String> = []
    var hangs: Set<String> = []
    /// Called when an app agrees to quit (tests update their live running set).
    var onQuit: (String) -> Void = { _ in }
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
        if quits.contains(id) { onQuit(id); return true }
        return false
    }
}

/// A thread-safe running set the tests change while a flow runs.
private final class LiveSet: @unchecked Sendable {
    private let lock = NSLock()
    private var set: Set<String>
    init(_ set: Set<String>) { self.set = set }
    var value: Set<String> {
        get { lock.withLock { set } }
        set { lock.withLock { set = newValue } }
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
        #expect(CloseApps.statusText(.stillOpen) == "Still open, its files will stay")
    }

    @Test func appsAreOfferedOnlyForFilesThatWouldOtherwiseMove() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "com.apple.Safari/blob"), bytes: 65536)
        let model = model(rig, running: ["com.apple.Safari"])
        await scanned(model)
        model.cleanupSkip = CleanupSkip(categories: [.userCaches], folders: [])
        #expect(model.openAppHolders(running: [app("com.apple.Safari", "Safari")]).isEmpty)
    }

    @Test func relaunchedOwnerAfterARecheckKeepsItsFilesSafe() async throws {
        let rig = try ModelRig()
        let safari = try rig.file(rig.cachesDirectory.appending(path: "com.apple.Safari/blob"), bytes: 65536)
        let running = LiveSet(["com.apple.Safari"])
        let model = model(rig, running: ["com.apple.Safari"])
        model.runningBundleIDs = { running.value }
        await scanned(model)
        let before = model.selectedBytes

        running.value = []
        model.recheckInUse(running: running.value)
        #expect(model.selectedBytes > before)   // freed while Safari is closed

        running.value = ["com.apple.Safari"]   // reopened before cleaning
        await model.clean()
        guard case .done(let record) = model.state else { Issue.record("expected done"); return }
        #expect(FileManager.default.fileExists(atPath: safari.path))
        #expect(record.entries.contains { $0.outcome == .skipped(reason: "in use by com.apple.Safari") })
    }

    @Test func cancelAfterARecheckKeepsTheProtection() async throws {
        let rig = try ModelRig()
        let safari = try rig.file(rig.cachesDirectory.appending(path: "com.apple.Safari/blob"), bytes: 65536)
        let running = LiveSet(["com.apple.Safari"])
        let model = model(rig, running: ["com.apple.Safari"])
        model.runningBundleIDs = { running.value }
        await scanned(model)

        // The sheet's flow: Safari didn't quit; the user cancels and later presses Move to Trash.
        let quitter = ScriptedQuitter()
        let run = CloseAppsRun(holders: model.openAppHolders(running: [app("com.apple.Safari", "Safari")]))
        let promised = model.selectedBytes + run.holders.reduce(0) { $0 + $1.bytes }
        let result = await model.quitAndCleanFlow(run, quitter: quitter, timeout: .milliseconds(100), promised: promised)
        guard case .askAgain = result else { Issue.record("expected ask again"); return }

        await model.clean()   // the plain Move to Trash path
        #expect(FileManager.default.fileExists(atPath: safari.path))
    }

    @Test func flowCleansWhenEveryAppClosed() async throws {
        let rig = try ModelRig()
        let safari = try rig.file(rig.cachesDirectory.appending(path: "com.apple.Safari/blob"), bytes: 65536)
        try rig.file(rig.cachesDirectory.appending(path: "plain.log"), bytes: 4096)
        let running = LiveSet(["com.apple.Safari"])
        let model = model(rig, running: ["com.apple.Safari"])
        model.runningBundleIDs = { running.value }
        await scanned(model)
        let quitter = ScriptedQuitter()
        quitter.quits = ["com.apple.Safari"]
        quitter.onQuit = { running.value.remove($0) }
        let run = CloseAppsRun(holders: model.openAppHolders(running: [app("com.apple.Safari", "Safari")]))
        let promised = model.selectedBytes + run.holders.reduce(0) { $0 + $1.bytes }

        let result = await model.quitAndCleanFlow(run, quitter: quitter, timeout: .milliseconds(500), promised: promised)

        #expect(result == .cleaned)
        guard case .done(let record) = model.state else { Issue.record("expected done"); return }
        #expect(record.bytesMovedToTrash == promised)
        #expect(!FileManager.default.fileExists(atPath: safari.path))
        #expect(model.closedApps == ["Safari"])
        #expect(CloseApps.summaryLine(model.closedApps) == "Closed Safari before cleaning.")
        await scanned(model)
        #expect(model.closedApps.isEmpty)
    }

    @Test func flowAsksAgainWhenAnAppStayedOpen() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "com.apple.Safari/blob"), bytes: 65536)
        let slack = try rig.file(rig.cachesDirectory.appending(path: "com.tinyspeck.slack/blob"), bytes: 8192)
        let running = LiveSet(["com.apple.Safari", "com.tinyspeck.slack"])
        let model = model(rig, running: running.value)
        model.runningBundleIDs = { running.value }
        await scanned(model)
        let quitter = ScriptedQuitter()
        quitter.quits = ["com.apple.Safari"]
        quitter.onQuit = { running.value.remove($0) }
        let run = CloseAppsRun(holders: model.openAppHolders(
            running: [app("com.apple.Safari", "Safari"), app("com.tinyspeck.slack", "Slack")]))
        let promised = model.selectedBytes + run.holders.reduce(0) { $0 + $1.bytes }

        let result = await model.quitAndCleanFlow(run, quitter: quitter, timeout: .milliseconds(100), promised: promised)

        guard case .askAgain(let now, let line) = result else { Issue.record("expected ask again"); return }
        #expect(now == model.selectedBytes && now < promised)
        #expect(line.hasPrefix("Some apps stayed open"))
        #expect(run.statuses["com.tinyspeck.slack"] == .stillOpen)
        guard case .ready = model.state else { Issue.record("must not clean yet"); return }
        #expect(FileManager.default.fileExists(atPath: slack.path))
    }

    @Test func appThatTimedOutButClosedAfterwardsCounts() async throws {
        let rig = try ModelRig()
        let slack = try rig.file(rig.cachesDirectory.appending(path: "com.tinyspeck.slack/blob"), bytes: 8192)
        let running = LiveSet(["com.tinyspeck.slack"])
        let model = model(rig, running: running.value)
        model.runningBundleIDs = { running.value }
        await scanned(model)
        let quitter = ScriptedQuitter()
        quitter.hangs = ["com.tinyspeck.slack"]
        let run = CloseAppsRun(holders: model.openAppHolders(running: [app("com.tinyspeck.slack", "Slack")]))
        let promised = model.selectedBytes + run.holders.reduce(0) { $0 + $1.bytes }
        running.value = []   // it quit after all, just slower than the wait

        let result = await model.quitAndCleanFlow(run, quitter: quitter, timeout: .milliseconds(100), promised: promised)

        #expect(result == .cleaned)
        #expect(run.statuses["com.tinyspeck.slack"] == .closed)
        #expect(!FileManager.default.fileExists(atPath: slack.path))
        #expect(model.closedApps == ["Slack"])
    }

    @Test func changedLineWording() {
        #expect(CloseApps.changedLine(promised: 10, now: 10, someStillOpen: true) == nil)
        #expect(CloseApps.changedLine(promised: 3000, now: 1000, someStillOpen: true)
            == "Some apps stayed open, so their files stay where they are. 1 KB will move instead of 3 KB.")
        #expect(CloseApps.changedLine(promised: 1000, now: 3000, someStillOpen: false)
            == "What can move changed while the apps closed. 3 KB will move instead of 1 KB.")
    }
}
