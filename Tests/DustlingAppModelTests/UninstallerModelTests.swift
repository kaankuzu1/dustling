import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

@MainActor @Suite
struct UninstallerModelTests {
    private let dataText = "This is your data. It can hold the app's documents, saves and settings. "
        + "You can put it back from the Trash, but not after you empty it."

    /// Alpha with a disposable cache, a data folder, and a name-based folder.
    private func alphaRig() throws -> (ModelRig, URL) {
        let rig = try ModelRig()
        let app = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let lib = rig.environment.userLibrary
        try rig.file(lib.appending(path: "Caches/com.test.alpha/c.bin"), bytes: 4096)
        try rig.file(lib.appending(path: "Application Support/com.test.alpha/save.bin"), bytes: 4096)
        return (rig, app)
    }

    @Test func checkingDataRowShowsWarning() async throws {
        let (rig, _) = try alphaRig()
        let model = rig.uninstallerModel()
        await model.load()
        let alpha = try #require(model.apps.first)
        #expect(alpha.leftoverCount == 2)

        let support = try #require(model.leftovers(for: alpha.app).first { $0.leftover.kind == .applicationSupport })
        let caches = try #require(model.leftovers(for: alpha.app).first { $0.leftover.kind == .caches })
        #expect(caches.checked)
        #expect(caches.warning == nil)
        #expect(!support.checked)
        #expect(support.badges == [.yourData])
        #expect(support.warning == nil)

        model.setChecked(true, leftover: support.leftover, in: alpha.app)

        let after = try #require(model.leftovers(for: alpha.app).first { $0.leftover.kind == .applicationSupport })
        #expect(after.checked)
        #expect(after.warning == dataText)
        model.setChecked(false, leftover: support.leftover, in: alpha.app)
        #expect(model.leftovers(for: alpha.app).first { $0.leftover.kind == .applicationSupport }?.warning == nil)
    }

    @Test func confirmationSeparatesDataItems() async throws {
        let (rig, _) = try alphaRig()
        let running = FakeRunning()
        let model = rig.uninstallerModel(running: running)
        await model.load()
        let alpha = try #require(model.apps.first)
        let support = try #require(model.leftovers(for: alpha.app).first { $0.leftover.kind == .applicationSupport })
        model.selection = [alpha.app.url]
        running.set(alpha.app.url, running: true)

        var confirm = model.confirmation
        #expect(confirm.perApp.map(\.name) == ["Alpha"])
        #expect(confirm.perApp[0].items == 2)       // the app and its cache
        #expect(confirm.perApp[0].dataItems == 0)
        #expect(confirm.dataWarnings.isEmpty)
        #expect(confirm.runningApps == ["Alpha"])

        model.setChecked(true, leftover: support.leftover, in: alpha.app)
        confirm = model.confirmation
        #expect(confirm.perApp[0].items == 2)
        #expect(confirm.perApp[0].dataItems == 1)
        #expect(confirm.dataWarnings.map(\.appName) == ["Alpha"])
        #expect(confirm.dataWarnings.map(\.text) == [dataText])
        #expect(confirm.totalBytes == confirm.perApp[0].bytes)
        #expect(confirm.totalBytes > alpha.app.bytes)
    }

    @Test func runningAppThatWontQuitIsSkippedOthersProceed() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let beta = try rig.makeApp("Beta", bundleID: "com.test.beta")
        try rig.file(rig.environment.userLibrary.appending(path: "Caches/com.test.beta/c.bin"), bytes: 1024)
        let running = FakeRunning()
        running.set(alpha, running: true)
        let completed = Counter()
        let model = rig.uninstallerModel(running: running, onRunCompleted: { completed.bump() })
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let quitter = FakeQuitter(running: running)   // refuses to quit Alpha

        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: quitter)

        #expect(records.count == 2)
        let alphaRecord = try #require(records.first { $0.kind == .uninstall(appName: "Alpha") })
        #expect(alphaRecord.entries.first?.outcome == .skipped(reason: "still running after Dustling asked it to quit"))
        #expect(FileManager.default.fileExists(atPath: alpha.path))
        let betaRecord = try #require(records.first { $0.kind == .uninstall(appName: "Beta") })
        if case .movedToTrash = betaRecord.entries.first?.outcome {} else { Issue.record("Beta should be in the Trash") }
        #expect(!FileManager.default.fileExists(atPath: beta.path))
        #expect(!FileManager.default.fileExists(
            atPath: rig.environment.userLibrary.appending(path: "Caches/com.test.beta").path))
        #expect(completed.value == 2)
        #expect(quitter.askedNames == ["Alpha"])
        // Both are in History.
        #expect(try rig.journal.all().count == 2)
        #expect(model.apps.map(\.app.displayName) == ["Alpha"])
    }

    @Test func runningAppThatQuitsIsUninstalled() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let running = FakeRunning()
        running.set(alpha, running: true)
        let model = rig.uninstallerModel(running: running)
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let quitter = FakeQuitter(running: running)
        quitter.quits = ["Alpha"]

        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: quitter)

        if case .movedToTrash = records.first?.entries.first?.outcome {} else { Issue.record("expected moved") }
        #expect(!FileManager.default.fileExists(atPath: alpha.path))
    }

    @Test func quitThatNeverAnswersTimesOut() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let running = FakeRunning()
        running.set(alpha, running: true)
        let model = rig.uninstallerModel(running: running, quitTimeout: .milliseconds(100))
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let quitter = FakeQuitter(running: running)
        quitter.hangs = ["Alpha"]

        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: quitter)

        #expect(records.first?.entries.first?.outcome == .skipped(reason: "still running after Dustling asked it to quit"))
        #expect(FileManager.default.fileExists(atPath: alpha.path))
    }

    @Test func excludedLeftoverIsShownUncheckedAndDisabled() async throws {
        let (rig, _) = try alphaRig()
        let excluded = rig.environment.userLibrary.appending(path: "Caches/com.test.alpha")
        let protected = ProtectedPaths(environment: rig.environment, extraDenied: [excluded])
        let model = rig.uninstallerModel(protectedPaths: protected)
        await model.load()
        let alpha = try #require(model.apps.first)
        let caches = try #require(model.leftovers(for: alpha.app).first { $0.leftover.kind == .caches })

        #expect(!caches.checked)
        #expect(caches.isDisabled)
        #expect(caches.disabledReason == "excluded in Settings")
        model.setChecked(true, leftover: caches.leftover, in: alpha.app)
        #expect(model.leftovers(for: alpha.app).first { $0.leftover.kind == .caches }?.checked == false)
        model.selection = [alpha.app.url]
        #expect(model.confirmation.perApp[0].items == 1)   // just the app
    }

    @Test func symlinkedAppIsAShortcutWithNothingPreselected() async throws {
        let rig = try ModelRig()
        let real = try rig.makeApp("Real", bundleID: "com.test.real", in: rig.root.appending(path: "Elsewhere"))
        try FileManager.default.createSymbolicLink(
            at: rig.applicationsDirectory.appending(path: "Real.app"), withDestinationURL: real)
        try rig.file(rig.environment.userLibrary.appending(path: "Caches/com.test.real/c.bin"), bytes: 1024)
        let model = rig.uninstallerModel()
        await model.load()
        let row = try #require(model.apps.first)

        #expect(row.label == "Shortcut")
        #expect(row.warning?.contains("Only the link is removed") == true)
        let rows = model.leftovers(for: row.app)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { !$0.checked && $0.disabledReason == "Only the link is removed" })

        model.selection = [row.app.url]
        #expect(model.confirmation.perApp[0].items == 1)   // only the link, whatever is ticked
    }

    @Test func steamWrapperIsLabelled() async throws {
        let rig = try ModelRig()
        let app = try rig.makeApp("Portal", bundleID: nil, executable: "run")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try "#!/bin/sh\nopen steam://run/400\n".write(to: macOS.appending(path: "run"), atomically: true, encoding: .utf8)
        let model = rig.uninstallerModel()
        await model.load()
        #expect(model.apps.first?.label == "Steam game")
    }

    @Test func nestedAppsAreNotAmongOthers() {
        func app(_ path: String, _ id: String) -> InstalledApp {
            InstalledApp(
                url: URL(filePath: path), displayName: id, bundleID: id, teamID: nil, executableName: nil,
                steamAppID: nil, bytes: 0, lastUsed: nil)
        }
        let target = app("/Applications/Suite.app", "com.s")
        let nested = app("/Applications/Suite.app/Contents/Helpers/Helper.app", "com.s.helper")
        let sibling = app("/Applications/Suite Two.app", "com.s2")
        let others = UninstallerModel.others(than: target, in: [target, nested, sibling])
        #expect(others.map(\.bundleID) == ["com.s2"])
    }

    @Test func badgesFollowTheLeftover() {
        let app = InstalledApp(
            url: URL(filePath: "/Applications/A.app"), displayName: "A", bundleID: "com.a", teamID: "ABCDE12345",
            executableName: nil, steamAppID: nil, bytes: 0, lastUsed: nil)
        let paths = ProtectedPaths(environment: .current)
        func badges(_ kind: LeftoverKind, _ match: MatchStrength, data: Bool, admin: Bool) -> [LeftoverBadge] {
            let leftover = Leftover(
                url: URL(filePath: "/nonexistent/x"), kind: kind, match: match, mayContainUserData: data,
                requiresAdmin: admin, bytes: 1)
            return UninstallerModel.makeRow(leftover, for: app, protectedPaths: paths).badges
        }
        #expect(badges(.groupContainer, .exact, data: true, admin: false) == [.teamID, .yourData])
        #expect(badges(.groupContainer, .nameBased, data: true, admin: false) == [.nameMatch, .yourData])
        #expect(badges(.launchDaemon, .exact, data: false, admin: true) == [.helper])
        #expect(badges(.caches, .nameBased, data: false, admin: false) == [.nameMatch])
    }

    @Test func untickedCacheStaysUntickedAfterReload() async throws {
        let (rig, _) = try alphaRig()
        let model = rig.uninstallerModel()
        await model.load()
        let alpha = try #require(model.apps.first)
        let caches = try #require(model.leftovers(for: alpha.app).first { $0.leftover.kind == .caches })
        model.setChecked(false, leftover: caches.leftover, in: alpha.app)

        await model.load()

        let after = try #require(model.leftovers(for: alpha.app).first { $0.leftover.kind == .caches })
        #expect(!after.checked)
    }

    @Test func reloadDuringUninstallUsesTheConfirmedPlan() async throws {
        let (rig, app) = try alphaRig()
        let running = FakeRunning()
        running.set(app, running: true)
        let model = rig.uninstallerModel(running: running)
        await model.load()
        let alpha = try #require(model.apps.first)
        let caches = try #require(model.leftovers(for: alpha.app).first { $0.leftover.kind == .caches })
        model.setChecked(false, leftover: caches.leftover, in: alpha.app)   // the user unticked it
        model.selection = [alpha.app.url]
        let quitter = HookQuitter(running: running) {
            // While the app is quitting: a reload is attempted and the box gets ticked again.
            await model.load()
            await MainActor.run { model.setChecked(true, leftover: caches.leftover, in: alpha.app) }
        }

        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: quitter)

        if case .movedToTrash = records.first?.entries.first?.outcome {} else { Issue.record("expected moved") }
        #expect(records.first?.entries.count == 1)   // only the app
        #expect(FileManager.default.fileExists(
            atPath: rig.environment.userLibrary.appending(path: "Caches/com.test.alpha").path))
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(!model.isUninstalling)
    }

    @Test func appsShowBeforeLeftoversAreCounted() async throws {
        let (rig, _) = try alphaRig()
        try rig.makeApp("Beta", bundleID: "com.test.beta")
        let commands = FakeCommands()
        let gate = Gate()
        commands.pkgutilGate = gate
        let model = rig.uninstallerModel(commands: commands)

        let loading = Task { await model.load() }
        let shown = await waitUntil { model.apps.count == 2 }
        #expect(shown)
        #expect(model.apps.allSatisfy { $0.isCounting })
        #expect(model.isLoading)

        gate.open()
        _ = await loading.value

        #expect(model.apps.allSatisfy { !$0.isCounting })
        #expect(model.apps.first { $0.app.displayName == "Alpha" }?.leftoverCount == 2)
        #expect(!model.isLoading)
    }

    @Test func helperOnlyLeftoversAreCountedApart() async throws {
        let (rig, _) = try alphaRig()
        let daemons = rig.environment.systemLibrary.appending(path: "LaunchDaemons")
        let plist = try rig.writeLaunchPlist(daemons, label: "com.test.alpha.daemon", program: "/x/y")
        let model = rig.uninstallerModel()
        await model.load()
        let alpha = try #require(model.apps.first)
        let admin = try #require(model.leftovers(for: alpha.app).first { $0.leftover.url.lastPathComponent == plist.lastPathComponent })
        #expect(admin.badges.contains(.helper))
        model.selection = [alpha.app.url]
        let withAdmin = model.confirmation
        #expect(admin.checked)
        #expect(withAdmin.adminItems == 1)
        #expect(withAdmin.adminNote == "Needs the cleanup helper")
        #expect(withAdmin.perApp[0].adminItems == 1)
        #expect(withAdmin.perApp[0].items == 2)   // the app and its cache, not the daemon
        model.setChecked(false, leftover: admin.leftover, in: alpha.app)
        #expect(model.confirmation.totalBytes == withAdmin.totalBytes)   // never in what is freed
        #expect(model.confirmation.adminItems == 0)
        #expect(model.confirmation.adminNote == nil)
    }

    @Test func uninstallExecutesTheConfirmationNotLaterTicks() async throws {
        let (rig, app) = try alphaRig()
        let model = rig.uninstallerModel()
        await model.load()
        let alpha = try #require(model.apps.first)
        model.selection = [alpha.app.url]
        let confirmed = model.confirmation           // the sheet the user approved
        #expect(confirmed.ready)
        let support = try #require(model.leftovers(for: alpha.app).first { $0.leftover.kind == .applicationSupport })
        model.setChecked(true, leftover: support.leftover, in: alpha.app)   // something changes meanwhile
        await model.load()

        let records = await model.uninstallSelected(confirmed: confirmed, quit: FakeQuitter(running: FakeRunning()))

        #expect(records.first?.entries.count == 2)   // the app and its cache
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(FileManager.default.fileExists(
            atPath: rig.environment.userLibrary.appending(path: "Application Support/com.test.alpha").path))
    }

    @Test func uninstallWhileCountingIsRefused() async throws {
        let (rig, app) = try alphaRig()
        let commands = FakeCommands()
        let gate = Gate()
        commands.pkgutilGate = gate
        let model = rig.uninstallerModel(commands: commands)
        let loading = Task { await model.load() }
        #expect(await waitUntil { model.apps.count == 1 })
        model.selection = Set(model.apps.map(\.app.url))

        let confirmed = model.confirmation
        #expect(!confirmed.ready)
        #expect(confirmed.note == "Still looking for leftovers")
        let records = await model.uninstallSelected(confirmed: confirmed, quit: FakeQuitter(running: FakeRunning()))

        #expect(records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: app.path))
        gate.open()
        _ = await loading.value
        #expect(model.confirmation.ready)
    }

    @Test func interruptedLoadIsRunAgainAfterUninstall() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        try rig.makeApp("Beta", bundleID: "com.test.beta")
        let running = FakeRunning()
        running.set(alpha, running: true)
        let commands = FakeCommands()
        let gate = Gate()
        commands.pkgutilGate = gate
        commands.gateOnly = "Beta"
        let model = rig.uninstallerModel(running: running, commands: commands)
        let loading = Task { await model.load() }
        let ready = await waitUntil {
            model.apps.count == 2 && model.apps.first { $0.app.displayName == "Alpha" }?.isCounting == false
        }
        #expect(ready)
        model.selection = model.apps.filter { $0.app.displayName == "Alpha" }.map(\.app.url).reduce(into: []) { $0.insert($1) }
        let confirmed = model.confirmation
        #expect(confirmed.ready)
        // The load is still waiting on Beta when the uninstall starts, and stays held after it.
        running.set(alpha, running: false)

        let records = await model.uninstallSelected(confirmed: confirmed, quit: FakeQuitter(running: running))

        // The results came back while the recount is still held at Beta.
        #expect(records.count == 1)
        #expect(model.apps.map(\.app.displayName) == ["Beta"])
        #expect(model.apps.allSatisfy { $0.isCounting })
        gate.open()
        _ = await loading.value
        #expect(await waitUntil { model.apps.allSatisfy { !$0.isCounting } })
        #expect(model.apps.first?.leftoverCount == 0)
    }

    // MARK: Task 13: the screen's flow

    @Test func aConfirmationIsUsedOnlyOnce() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let model = rig.uninstallerModel()
        model.canTakeOutOfTrash = true
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let confirm = model.confirmation

        let first = await model.uninstallSelected(confirmed: confirm, quit: FakeQuitter(running: FakeRunning()))
        #expect(first.count == 1)
        // Put it back by hand and try the same confirmation again: refused.
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        let again = await model.uninstallSelected(confirmed: confirm, quit: FakeQuitter(running: FakeRunning()))
        #expect(again.isEmpty)
        #expect(model.refusal == UninstallerModel.usedRefusal)
        #expect(FileManager.default.fileExists(atPath: alpha.path))
    }

    @Test func withoutTrashAccessTheConfirmationMustCarryTheWarning() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let model = rig.uninstallerModel()
        model.canTakeOutOfTrash = true
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let shownWithAccess = model.confirmation
        #expect(shownWithAccess.limitedNote == nil)

        // Access went away while the sheet was open: the sheet never warned, so nothing moves.
        model.canTakeOutOfTrash = false
        let refused = await model.uninstallSelected(confirmed: shownWithAccess, quit: FakeQuitter(running: FakeRunning()))
        #expect(refused.isEmpty)
        // Never silently: the screen says why nothing happened.
        #expect(model.refusal == UninstallerModel.accessRefusal)
        #expect(FileManager.default.fileExists(atPath: alpha.path))

        let warned = model.confirmation
        #expect(warned.limitedNote == CleanupGate.limitedNote)
        #expect(ConfirmText.make(warned).limitedNote == CleanupGate.limitedNote)
        let records = await model.uninstallSelected(confirmed: warned, quit: FakeQuitter(running: FakeRunning()))
        #expect(records.count == 1)
    }

    @Test func progressAndSummaryFollowTheRecords() async throws {
        let rig = try ModelRig()
        try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let beta = try rig.makeApp("Beta", bundleID: "com.test.beta")
        try rig.file(rig.environment.userLibrary.appending(path: "Caches/com.test.beta/c.bin"), bytes: 1024)
        let running = FakeRunning()
        running.set(beta, running: true)
        let model = rig.uninstallerModel(running: running)
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))

        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: FakeQuitter(running: running))

        let progress = try #require(model.progress)
        #expect(progress.apps.map(\.app.displayName) == ["Alpha", "Beta"])
        #expect(progress.apps.map(\.state) == [.finished(removed: true), .finished(removed: false)])
        #expect(progress.apps[0].items.allSatisfy { if case .finished(.movedToTrash) = $0.state { true } else { false } })
        #expect(progress.current == nil)
        let result = try #require(model.result)
        #expect(result.records == records)
        #expect(result.stopped.isEmpty)
        let summary = UninstallSummary.make(records: result.records, stopped: result.stopped, home: rig.environment.home)
        #expect(summary.sentence == "1 app moved to the Trash. Beta was left alone: still running after Dustling asked it to quit.")
        #expect(summary.movedBytes == records[0].bytesMovedToTrash)
        model.dismissResult()
        #expect(model.result == nil && model.progress == nil)
    }

    @Test func stopLeavesTheAppsNotYetStartedAlone() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let beta = try rig.makeApp("Beta", bundleID: "com.test.beta")
        let running = FakeRunning()
        running.set(alpha, running: true)
        let model = rig.uninstallerModel(running: running)
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        // Stop is pressed while Alpha is being quit.
        let quitter = HookQuitter(running: running) { await MainActor.run { model.stop() } }

        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: quitter)

        #expect(records.map(\.kind) == [.uninstall(appName: "Alpha")])
        #expect(!FileManager.default.fileExists(atPath: alpha.path))
        #expect(FileManager.default.fileExists(atPath: beta.path))
        #expect(model.result?.stopped == ["Beta"])
        #expect(model.progress?.apps.map(\.state) == [.finished(removed: true), .stopped])
    }

    @Test func putBackRestoresTheAppAndRefreshesTheLastRun() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let cache = try rig.file(rig.environment.userLibrary.appending(path: "Caches/com.test.alpha/c.bin"), bytes: 512)
        let completed = Counter()
        let model = rig.uninstallerModel(onRunCompleted: { completed.bump() })
        model.canTakeOutOfTrash = true
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: FakeQuitter(running: FakeRunning()))
        #expect(!FileManager.default.fileExists(atPath: alpha.path))
        #expect(completed.value == 1)

        let outcomes = try await model.putBack(records[0])

        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { if case .restored = $0 { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: alpha.path))
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(completed.value == 2)
        #expect(model.restoreOutcomes[records[0].id] == outcomes)
        await #expect(throws: UninstallerModelError.alreadyPutBack) { try await model.putBack(records[0]) }
        #expect(await waitUntil { model.apps.contains { $0.app.displayName == "Alpha" } })
    }

    @Test func putBackIsRefusedWithoutTrashAccess() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let model = rig.uninstallerModel()
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: FakeQuitter(running: FakeRunning()))
        #expect(records.count == 1)

        await #expect(throws: UninstallerModelError.cantTakeOutOfTrash) { try await model.putBack(records[0]) }
        #expect(!FileManager.default.fileExists(atPath: alpha.path))
    }

    // MARK: fix round 1

    @Test func revokedAccessNeverMovesOtherAppsData() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let lib = rig.environment.userLibrary
        let container = try rig.file(lib.appending(path: "Containers/com.test.alpha/Data/doc.bin"), bytes: 2048)
        let cache = try rig.file(lib.appending(path: "Caches/com.test.alpha/c.bin"), bytes: 1024)
        let model = rig.uninstallerModel()
        model.canTakeOutOfTrash = true
        await model.load()
        let row = try #require(model.apps.first)
        let containerRow = try #require(model.leftovers(for: row.app).first { $0.leftover.kind == .container })
        model.setChecked(true, leftover: containerRow.leftover, in: row.app)
        model.selection = [row.app.url]
        let confirm = model.confirmation

        // Full Disk Access is revoked after the list loaded.
        model.canReadAppData = false
        let records = await model.uninstallSelected(confirmed: confirm, quit: FakeQuitter(running: FakeRunning()))

        let record = try #require(records.first)
        #expect(!FileManager.default.fileExists(atPath: alpha.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(FileManager.default.fileExists(atPath: container.path))
        let containerPath = containerRow.leftover.url.path(percentEncoded: false)
        let entries = record.entries.filter { $0.originalPath == containerPath }
        #expect(entries.map(\.outcome) == [.skipped(reason: "needs Full Disk Access")])
        #expect(try rig.journal.all().first?.entries.contains { $0.originalPath == containerPath } == true)
    }

    @Test func lockedFoldersAreSkippedToo() async throws {
        let rig = try ModelRig()
        try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let cache = try rig.file(rig.environment.userLibrary.appending(path: "Caches/com.test.alpha/c.bin"), bytes: 1024)
        let model = rig.uninstallerModel()
        model.canTakeOutOfTrash = true
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        model.lockedFolders = [rig.environment.userLibrary.appending(path: "Caches")]
        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: FakeQuitter(running: FakeRunning()))
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(records.first?.entries.contains { $0.outcome == .skipped(reason: "needs Full Disk Access") } == true)
    }

    @Test func loadIsRefusedWithoutAppDataAccess() async throws {
        let rig = try ModelRig()
        try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let model = rig.uninstallerModel()
        model.canReadAppData = false
        #expect(await model.load() == false)
        #expect(model.apps.isEmpty)
        model.canReadAppData = true
        #expect(await model.load() == true)
        #expect(model.apps.count == 1)
        #expect(!model.isLoading)
    }

    @Test func anAppOpenedAfterConfirmingIsLeftAloneNotQuit() async throws {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let running = FakeRunning()
        let model = rig.uninstallerModel(running: running)
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let confirm = model.confirmation
        #expect(confirm.runningApps.isEmpty)
        running.set(alpha, running: true)
        let quitter = FakeQuitter(running: running)
        quitter.quits = ["Alpha"]

        let records = await model.uninstallSelected(confirmed: confirm, quit: quitter)

        #expect(quitter.askedNames.isEmpty)
        #expect(records.first?.entries.first?.outcome == .skipped(reason: "opened after you confirmed"))
        #expect(FileManager.default.fileExists(atPath: alpha.path))
    }

    // MARK: fix round 2

    @Test func appDataReadingIsOffUntilAccessIsKnown() async throws {
        let rig = try ModelRig()
        let runner = rig.runner()
        let model = UninstallerModel(
            scout: AppScout(environment: rig.environment),
            finder: LeftoverFinder(environment: rig.environment, sizer: DirectorySizer(), commands: FakeCommands()),
            uninstaller: Uninstaller(runner: runner, commands: FakeCommands(), running: FakeRunning(),
                                     environment: rig.environment),
            running: FakeRunning(), protectedPaths: runner.protectedPaths, journal: rig.journal,
            logger: RunLogger(directory: rig.environment.logsDirectory))
        #expect(!model.canReadAppData)
    }

    @Test func confirmationLeavesOutWhatWillBeSkipped() async throws {
        let rig = try ModelRig()
        try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let lib = rig.environment.userLibrary
        try rig.file(lib.appending(path: "Containers/com.test.alpha/Data/doc.bin"), bytes: 50_000)
        let model = rig.uninstallerModel()
        await model.load()
        let row = try #require(model.apps.first)
        let container = try #require(model.leftovers(for: row.app).first { $0.leftover.kind == .container })
        model.setChecked(true, leftover: container.leftover, in: row.app)
        model.selection = [row.app.url]
        let withAccess = model.confirmation
        #expect(withAccess.dataWarnings.count == 1)
        #expect(withAccess.accessSkipped == 0)

        model.canReadAppData = false
        let without = model.confirmation
        #expect(without.dataWarnings.isEmpty)
        #expect(without.accessSkipped == 1)
        #expect(without.totalBytes == withAccess.totalBytes - container.leftover.bytes)
        #expect(without.perApp[0].items + without.perApp[0].dataItems
            == withAccess.perApp[0].items + withAccess.perApp[0].dataItems - 1)
        #expect(ConfirmText.make(without).notes.contains("1 item needs Full Disk Access and stays where it is."))
    }
}
