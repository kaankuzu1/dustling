import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

@MainActor
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

        await model.clean()

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

        let cleaning = Task { await model.clean() }
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
        await model.clean()
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
        await model.clean()
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
