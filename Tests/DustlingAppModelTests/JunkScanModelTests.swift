import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

@MainActor @Suite
struct JunkScanModelTests {
    private func makeModel(
        _ rig: ModelRig, running: Set<String> = [], failing: Set<String> = [], preselectSafe: Bool = true,
        cachesFilter: @escaping @Sendable (URL) -> Bool = { _ in true },
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) -> JunkScanModel {
        let categories = rig.categories(cachesFilter: cachesFilter)
        return JunkScanModel(
            scanner: rig.scanner(running: running), runner: rig.runner(failing: failing),
            journal: rig.journal, environment: rig.environment, options: rig.options,
            preselectSafe: preselectSafe, categories: { categories }, onRunCompleted: onRunCompleted)
    }

    private func scanned(_ model: JunkScanModel) async {
        model.scan()
        await model.awaitScan()
    }

    @Test func scanFillsTilesAsCategoriesFinish() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "com.a.app/blob"), bytes: 4096)
        try rig.file(rig.backupsDirectory.appending(path: "device1/data"), bytes: 8192)
        let gate = Gate()
        // The review category is only reached after the first tile is in; hold the scan inside it.
        let categories = [
            rig.categories()[0],
            JunkCategory(
                id: .iosBackups, title: "iPhone and iPad backups", selection: .review, requiresAdmin: false,
                roots: [rig.backupsDirectory], itemFilter: { _ in gate.wait(); return true }),
        ]
        let model = JunkScanModel(
            scanner: rig.scanner(), runner: rig.runner(), journal: rig.journal,
            environment: rig.environment, options: rig.options, categories: { categories })

        model.scan()
        guard case .scanning = model.state else { Issue.record("expected scanning"); return }
        #expect(await waitUntil { gate.hasEntered && model.categories.count == 1 })
        #expect(model.categories[0].id == .userCaches)
        #expect(model.categories[0].itemCount == 1)
        #expect(model.categories[0].bytes > 0)
        guard case .scanning = model.state else { Issue.record("still scanning"); gate.open(); return }

        gate.open()
        await model.awaitScan()
        guard case .ready = model.state else { Issue.record("expected ready"); return }
        #expect(model.categories.map(\.id) == [.userCaches, .iosBackups])
        #expect(model.categories.allSatisfy { !$0.stopped })
    }

    @Test func scanRecordsWhenItFinished() async throws {
        let rig = try ModelRig()
        let model = makeModel(rig)
        #expect(model.lastScanFinishedAt == nil)
        let before = Date.now
        await scanned(model)
        let finished = try #require(model.lastScanFinishedAt)
        #expect(finished >= before && finished <= .now)
    }

    @Test func stopMarksPartialCategory() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "com.a.app/blob"), bytes: 4096)
        let gate = Gate()
        let model = makeModel(rig, cachesFilter: { _ in gate.wait(); return true })

        model.scan()
        #expect(await waitUntil { gate.hasEntered })
        model.stop()
        gate.open()
        await model.awaitScan()

        guard case .ready = model.state else { Issue.record("expected ready after stop"); return }
        let caches = try #require(model.categories.first { $0.id == .userCaches })
        #expect(caches.stopped)
        #expect(!caches.isSelected)
        // The category after the stopped one was never scanned; it is shown as such, not as empty.
        let backups = try #require(model.categories.first { $0.id == .iosBackups })
        #expect(backups.stopped)
        #expect(model.selectedBytes == 0)
        // A stopped tile can't be ticked.
        model.toggle(.userCaches)
        #expect(!model.categories[0].isSelected)
    }

    @Test func reviewCategoriesStartUnchecked() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "com.a.app/blob"), bytes: 4096)
        try rig.file(rig.backupsDirectory.appending(path: "device1/data"), bytes: 8192)
        let model = makeModel(rig)
        await scanned(model)

        let caches = try #require(model.categories.first { $0.id == .userCaches })
        let backups = try #require(model.categories.first { $0.id == .iosBackups })
        #expect(caches.isSelected)
        #expect(!backups.isSelected)
        #expect(backups.note == "Your data, never selected for you")
        #expect(caches.note == nil)
        #expect(model.selectedBytes == caches.bytes)

        model.toggle(.iosBackups)
        #expect(model.categories.first { $0.id == .iosBackups }?.isSelected == true)
        #expect(model.selectedBytes == caches.bytes + backups.bytes)
    }

    @Test func preselectSafeOffStartsEverythingUnchecked() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "com.a.app/blob"), bytes: 4096)
        let model = makeModel(rig, preselectSafe: false)
        await scanned(model)
        #expect(model.categories.allSatisfy { !$0.isSelected })
        #expect(model.selectedBytes == 0)
    }

    @Test func inUseItemsAreCountedAndNotSelectedBytes() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "com.a.app/blob"), bytes: 4096)
        try rig.file(rig.cachesDirectory.appending(path: "com.open.app/blob"), bytes: 4096)
        let model = makeModel(rig, running: ["com.open.app"])
        await scanned(model)
        let caches = try #require(model.categories.first { $0.id == .userCaches })
        #expect(caches.inUseCount == 1)
        #expect(caches.itemCount == 2)
        #expect(model.selectedBytes < caches.bytes)
        #expect(model.selectedBytes > 0)
    }

    @Test func summaryUsesActualOutcomes() async throws {
        let rig = try ModelRig()
        let a = try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let b = try rig.file(rig.cachesDirectory.appending(path: "b.log"), bytes: 8192)
        try rig.file(rig.cachesDirectory.appending(path: "boom.log"), bytes: 4096)
        try rig.file(rig.cachesDirectory.appending(path: "com.open.app/blob"), bytes: 4096)
        let movedBytes = DirectorySizer().measure(a).bytes + DirectorySizer().measure(b).bytes
        let completed = Counter()
        let model = makeModel(
            rig, running: ["com.open.app"], failing: ["boom.log"], onRunCompleted: { completed.bump() })
        await scanned(model)
        #expect(model.selectedBytes > movedBytes)   // what the scan hoped for is more than what happens

        await model.clean(confirmedLimited: true)

        guard case .done(let record) = model.state else { Issue.record("expected done"); return }
        let summary = try #require(model.summary)
        #expect(summary.movedCount == 2)
        #expect(summary.movedBytes == movedBytes)
        #expect(summary.movedBytes == record.bytesMovedToTrash)
        #expect(summary.skipped.count == 1)
        #expect(summary.skipped[0].reason == "in use by com.open.app")
        #expect(summary.skipped[0].path.contains("com.open.app"))
        #expect(summary.failed.count == 1)
        #expect(summary.failed[0].reason.contains("disk exploded"))
        #expect(summary.failed[0].path.hasSuffix("boom.log"))
        #expect(summary.needsAdminCount == 0)
        #expect(completed.value == 1)
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }

    @Test func cleanReportsPerItemProgress() async throws {
        let rig = try ModelRig()
        for name in ["a", "b", "c"] { try rig.file(rig.cachesDirectory.appending(path: "\(name).log"), bytes: 4096) }
        let gate = Gate()
        let categories = rig.categories()
        let model = JunkScanModel(
            scanner: rig.scanner(), runner: rig.runner(hold: (name: "b.log", gate: gate)), journal: rig.journal,
            environment: rig.environment, options: rig.options, categories: { categories })
        await scanned(model)

        let cleaning = Task { await model.clean(confirmedLimited: true) }
        #expect(await waitUntil { gate.hasEntered })   // "a" is moved, "b" is being moved
        #expect(await waitUntil {
            if case .moving(let done, let total, let bytes) = model.state { return done == 1 && total == 3 && bytes > 0 }
            return false
        })
        gate.open()
        await cleaning.value
        guard case .done(let record) = model.state else { Issue.record("expected done"); return }
        #expect(record.entries.count == 3)
    }

    @Test func nothingSelectedStaysReadyWithAMessage() async throws {
        let rig = try ModelRig()
        let model = makeModel(rig, preselectSafe: false)
        await scanned(model)
        await model.clean(confirmedLimited: true)
        guard case .ready = model.state else { Issue.record("expected ready"); return }
        #expect(model.message == "Nothing is selected to move to the Trash.")
    }

    @Test func adminCategoriesStartUncheckedAndCantBeToggled() async throws {
        let rig = try ModelRig()
        let sys = rig.root.appending(path: "Library/Caches", directoryHint: .isDirectory)
        try rig.file(sys.appending(path: "x/blob"), bytes: 4096)
        let categories = [JunkCategory(
            id: .systemCachesAndLogs, title: "System caches and logs", selection: .preselected,
            requiresAdmin: true, roots: [sys])]
        let model = JunkScanModel(
            scanner: rig.scanner(), runner: rig.runner(), journal: rig.journal,
            environment: rig.environment, options: rig.options, categories: { categories })
        await scanned(model)
        let tile = try #require(model.categories.first)
        #expect(!tile.isSelected)
        #expect(tile.bytes > 0)
        #expect(tile.note == "Needs the cleanup helper")
        model.toggle(.systemCachesAndLogs)
        #expect(!model.categories[0].isSelected)
        #expect(model.selectedBytes == 0)
    }

    @Test func putEverythingBackRestoresOnlyMovedItems() async throws {
        let rig = try ModelRig()
        let a = try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let b = try rig.file(rig.cachesDirectory.appending(path: "b.log"), bytes: 4096)
        let boom = try rig.file(rig.cachesDirectory.appending(path: "boom.log"), bytes: 4096)
        let open = try rig.file(rig.cachesDirectory.appending(path: "com.open.app/blob"), bytes: 4096)
        let completed = Counter()
        let model = makeModel(
            rig, running: ["com.open.app"], failing: ["boom.log"], onRunCompleted: { completed.bump() })
        await scanned(model)
        await model.clean(confirmedLimited: true)
        #expect(!FileManager.default.fileExists(atPath: a.path))

        let outcomes = try await model.putEverythingBack()

        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { if case .restored = $0 { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        // The failed and in-use items were never moved, so they were never touched.
        #expect(FileManager.default.fileExists(atPath: boom.path))
        #expect(FileManager.default.fileExists(atPath: open.path))
        #expect(completed.value == 2)   // after the clean and after the restore
        // Once per run.
        #expect(!model.canPutBack)
        await #expect(throws: JunkScanModelError.alreadyPutBack) { _ = try await model.putEverythingBack() }
    }

    @Test func putEverythingBackWithoutARunThrows() async throws {
        let rig = try ModelRig()
        let model = makeModel(rig)
        await #expect(throws: (any Error).self) { _ = try await model.putEverythingBack() }
    }
}

extension JunkScanModelTests {
    @Test func selectedBytesAreKnownPerCategory() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "com.a.app/blob"), bytes: 4096)
        try rig.file(rig.backupsDirectory.appending(path: "device1/data"), bytes: 8192)
        let model = makeModel(rig)
        await scanned(model)
        let caches = try #require(model.categories.first { $0.id == .userCaches })
        #expect(model.selectedBytesByCategory == [.userCaches: caches.bytes])
        model.toggle(.iosBackups)
        let backups = try #require(model.categories.first { $0.id == .iosBackups })
        #expect(model.selectedBytesByCategory == [.userCaches: caches.bytes, .iosBackups: backups.bytes])
        #expect(model.selectedBytes == caches.bytes + backups.bytes)
    }

    @Test func toggleClearsTheMessage() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let model = makeModel(rig, preselectSafe: false)
        await scanned(model)
        await model.clean(confirmedLimited: true)
        #expect(model.message != nil)
        model.toggle(.userCaches)
        #expect(model.message == nil)
    }

    @Test func putEverythingBackCantRunTwiceAtOnce() async throws {
        let rig = try ModelRig()
        let a = try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let completed = Counter()
        let model = makeModel(rig, onRunCompleted: { completed.bump() })
        await scanned(model)
        await model.clean(confirmedLimited: true)

        async let first = try? model.putEverythingBack()
        async let second = try? model.putEverythingBack()
        let results = await [first, second]

        let restored = results.compactMap { $0 }
        #expect(restored.count == 1)
        #expect(restored.first?.count == 1)
        #expect(!model.isRestoring)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(completed.value == 2)   // the clean and one restore
    }

    @Test func withoutTrashAccessCleaningWarnsOrIsRefusedByPolicy() async throws {
        #expect(CleanupGate.make(canTakeOutOfTrash: true, policy: .refuseToClean)
            == CleanupGate(kind: .allowed, note: nil, undo: .putEverythingBack))
        let warn = CleanupGate.make(canTakeOutOfTrash: false, policy: .warnBeforeCleaning)
        #expect(warn.kind == .confirmFirst && warn.undo == .showInTrash)
        #expect(warn.note == "Without Full Disk Access, Dustling can't put these back for you. "
            + "You can still drag them out of the Trash in Finder.")

        let rig = try ModelRig()
        let a = try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let model = makeModel(rig)
        await scanned(model)
        model.canTakeOutOfTrash = false
        model.limitedCleanupPolicy = .refuseToClean
        await model.clean(confirmedLimited: true)
        guard case .ready = model.state else { Issue.record("expected ready"); return }
        #expect(model.message == CleanupGate.refusedNote)
        #expect(FileManager.default.fileExists(atPath: a.path))

        model.limitedCleanupPolicy = .warnBeforeCleaning
        await model.clean(confirmedLimited: true)   // the view asked first
        guard case .done = model.state else { Issue.record("expected done"); return }
        #expect(model.cleanupGate.undo == .showInTrash)
    }

    @Test func cleanSkipsPlacesLockedSinceScan() async throws {
        let rig = try ModelRig()
        let a = try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let backup = try rig.file(rig.backupsDirectory.appending(path: "device1/data"), bytes: 8192)
        let model = makeModel(rig)
        model.canTakeOutOfTrash = true
        await scanned(model)
        model.toggle(.iosBackups)

        // The backups place was locked after the scan.
        await model.clean(skipping: CleanupSkip(categories: [.iosBackups], folders: []))

        guard case .done(let record) = model.state else { Issue.record("expected done"); return }
        let skipped = record.entries.filter { $0.outcome == .skipped(reason: "needs Full Disk Access") }
        #expect(skipped.count == 1)
        #expect(skipped.first?.originalPath.hasSuffix("MobileSync/Backup/device1/") == true)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: a.path))

        // A folder that is off limits now (e.g. other apps' containers) is left alone too.
        let rig2 = try ModelRig()
        let b = try rig2.file(rig2.cachesDirectory.appending(path: "b.log"), bytes: 4096)
        let model2 = makeModel(rig2)
        model2.canTakeOutOfTrash = true
        await scanned(model2)
        await model2.clean(skipping: CleanupSkip(categories: [], folders: [rig2.cachesDirectory]))
        guard case .done(let record2) = model2.state else { Issue.record("expected done"); return }
        #expect(record2.entries.allSatisfy { $0.outcome == .skipped(reason: "needs Full Disk Access") })
        #expect(record2.bytesMovedToTrash == 0)
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    @Test func unconfirmedCleanWithoutTrashAccessDoesNothing() async throws {
        let rig = try ModelRig()
        let a = try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let model = makeModel(rig)
        #expect(!model.canTakeOutOfTrash)   // unknown until the app says so
        await scanned(model)
        await model.clean()
        guard case .ready = model.state else { Issue.record("expected ready"); return }
        #expect(model.message == CleanupGate.limitedNote)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func putBackIsBusyWorkAndBlocksScanAndClean() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let model = makeModel(rig)
        model.canTakeOutOfTrash = true
        await scanned(model)
        await model.clean()
        guard case .done(let record) = model.state else { Issue.record("expected done"); return }

        let restoring = Task { try await model.putEverythingBack() }
        #expect(await yieldUntil { model.isRestoring })
        #expect(model.isBusy)
        model.scan()   // ignored while putting back
        guard case .done(let still) = model.state, still.id == record.id else { Issue.record("scan ran"); return }
        _ = try await restoring.value
        #expect(!model.isBusy)
        #expect(model.didPutBack)
        #expect(model.restoreOutcomes?.count == 1)
    }

    @Test func nothingRestoredKeepsPutBackAvailable() async throws {
        let rig = try ModelRig()
        let a = try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let model = makeModel(rig)
        model.canTakeOutOfTrash = true
        await scanned(model)
        await model.clean()
        guard case .done = model.state else { Issue.record("expected done"); return }
        try rig.file(a, bytes: 10)   // something new sits where it was

        let outcomes = try await model.putEverythingBack()

        #expect(outcomes.allSatisfy { if case .restored = $0 { false } else { true } })
        #expect(!model.didPutBack)
        #expect(model.restoreOutcomes == outcomes)
        #expect(JunkSummary.restoreHeadline(outcomes) == "Nothing was put back")
    }

    @Test func cleanTracksEachCategoryAndItsOutcomes() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        try rig.file(rig.cachesDirectory.appending(path: "boom.log"), bytes: 4096)
        try rig.file(rig.cachesDirectory.appending(path: "com.open.app/blob"), bytes: 4096)
        let model = makeModel(rig, running: ["com.open.app"], failing: ["boom.log"])
        await scanned(model)
        await model.clean(confirmedLimited: true)

        guard case .done(let record) = model.state else { Issue.record("expected done"); return }
        let progress = try #require(model.categoryProgress[.userCaches])
        #expect(progress.done == progress.total)
        #expect(progress.total == 2)   // the in-use item is never attempted
        let outcome = try #require(model.categoryOutcomes[.userCaches])
        #expect(outcome.movedBytes == record.bytesMovedToTrash)
        #expect(outcome.movedCount == 1)
        #expect(outcome.skippedCount == 1)
        #expect(outcome.failedCount == 1)
        #expect(model.categoryOutcomes[.iosBackups] == nil)
    }
}

/// A tiny thread-safe counter / recorder for callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var seen: [Int] = []
    var value: Int { lock.withLock { n } }
    var totals: [Int] { lock.withLock { seen } }
    func bump() { lock.withLock { n += 1 } }
    func record(_ total: Int) { lock.withLock { seen.append(total) } }
}
