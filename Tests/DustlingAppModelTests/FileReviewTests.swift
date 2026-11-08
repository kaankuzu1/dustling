import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// Review files: per-file exclusions before a cleanup.
@MainActor @Suite(.serialized)
struct FileReviewTests {
    private func makeModel(_ rig: ModelRig, running: Set<String> = []) -> JunkScanModel {
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

    private func bytes(_ url: URL) -> UInt64 { DirectorySizer().measure(url).bytes }

    /// The scanned URL of a file, as the sheet gets it (the scan may resolve /var to /private/var).
    private func scannedURL(_ model: JunkScanModel, _ name: String) throws -> URL {
        try #require(model.review(excluding: []).sections.flatMap(\.rows).first { $0.name == name }).url
    }

    @Test func excludedItemIsNeverMovedAndHasNoOutcome() async throws {
        let rig = try ModelRig()
        let keep = try rig.file(rig.cachesDirectory.appending(path: "keep.log"), bytes: 4096)
        let go = try rig.file(rig.cachesDirectory.appending(path: "go.log"), bytes: 8192)
        let model = makeModel(rig)
        await scanned(model)

        let keepURL = try scannedURL(model, "keep.log")
        model.setExclusions([keepURL])

        #expect(model.excludedItems == [keepURL])
        #expect(model.selectedBytes == bytes(go))
        #expect(model.selectedBytesByCategory == [.userCaches: bytes(go)])
        let tile = try #require(model.categories.first { $0.id == .userCaches })
        #expect(tile.excludedCount == 1)
        #expect(tile.excludedBytes == bytes(keep))

        await model.clean()
        guard case .done(let record) = model.state else { Issue.record("expected done"); return }
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!FileManager.default.fileExists(atPath: go.path))
        #expect(!record.entries.contains { $0.originalPath.hasSuffix("keep.log") })
        #expect(record.entries.count == 1)
    }

    @Test func exclusionsResetOnRescanAndUnknownFilesAreIgnored() async throws {
        let rig = try ModelRig()
        let a = try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        let model = makeModel(rig)
        await scanned(model)
        let aURL = try scannedURL(model, a.lastPathComponent)
        model.setExclusions([aURL, rig.root.appending(path: "nowhere.bin")])
        #expect(model.excludedItems == [aURL])
        await scanned(model)
        #expect(model.excludedItems.isEmpty)
        #expect(model.categories.first?.excludedCount == 0)
    }

    @Test func reviewListsSelectedCategoriesWithDisabledReasonsAndLiveTotals() async throws {
        let rig = try ModelRig()
        let small = try rig.file(rig.cachesDirectory.appending(path: "small.log"), bytes: 4096)
        let big = try rig.file(rig.cachesDirectory.appending(path: "big.log"), bytes: 65536)
        try rig.file(rig.cachesDirectory.appending(path: "com.open.app/blob"), bytes: 4096)
        try rig.file(rig.backupsDirectory.appending(path: "device1/data"), bytes: 8192)
        let model = makeModel(rig, running: ["com.open.app"])
        await scanned(model)

        let review = model.review(excluding: [], appName: { $0 == "com.open.app" ? "Open" : nil })
        // Only selected categories; backups are unchecked.
        #expect(review.sections.map(\.id) == [.userCaches])
        let rows = review.sections[0].rows
        #expect(rows.map(\.name) == ["big.log", "small.log", "com.open.app"])   // largest first, disabled last
        let open = try #require(rows.last)
        #expect(open.disabledReason == "In use by Open")
        #expect(!open.isIncluded)
        #expect(review.selectedCount == 2)
        #expect(review.selectedBytes == bytes(small) + bytes(big))
        #expect(review.sections[0].selectedBytes == review.selectedBytes)

        let bigURL = try scannedURL(model, big.lastPathComponent)
        let unticked = model.review(excluding: [bigURL])
        #expect(unticked.selectedCount == 1)
        #expect(unticked.selectedBytes == bytes(small))
        #expect(unticked.sections[0].rows.first { $0.url == bigURL }?.isIncluded == false)
        #expect(unticked.sections[0].rows.first { $0.url == bigURL }?.disabledReason == nil)

        // The sheet's live totals: same rows, same order, new totals.
        let applied = review.applying(excluding: [bigURL])
        #expect(applied.sections[0].rows.map(\.url) == review.sections[0].rows.map(\.url))
        #expect(applied.selectedBytes == unticked.selectedBytes && applied.selectedCount == unticked.selectedCount)
        #expect(applied.footerLine == "1 file selected, \(Bytes.format(bytes(small)))")

        // A place locked since the scan: its files are listed but can't move.
        let locked = model.review(excluding: [], skipping: CleanupSkip(categories: [.userCaches], folders: []))
        #expect(locked.selectedCount == 0)
        #expect(locked.sections[0].rows.allSatisfy { $0.disabledReason != nil })
        #expect(locked.sections[0].rows.first?.disabledReason == "Needs Full Disk Access")
    }
}
