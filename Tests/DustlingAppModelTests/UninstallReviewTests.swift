import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// Review all files: one list per selected app (the app, then its leftovers), the same movability rule
/// as the confirmation and the uninstall.
@MainActor @Suite(.serialized)
struct UninstallReviewTests {
    /// Alpha with a cache, a data folder (unchecked) and a container; Beta with a cache.
    private func rig() throws -> (ModelRig, UninstallerModel, URL, URL) {
        let rig = try ModelRig()
        let alpha = try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let beta = try rig.makeApp("Beta", bundleID: "com.test.beta")
        let lib = rig.environment.userLibrary
        try rig.file(lib.appending(path: "Caches/com.test.alpha/c.bin"), bytes: 4096)
        try rig.file(lib.appending(path: "Application Support/com.test.alpha/save.bin"), bytes: 4096)
        try rig.file(lib.appending(path: "Caches/com.test.beta/c.bin"), bytes: 1024)
        let model = rig.uninstallerModel()
        model.canTakeOutOfTrash = true
        return (rig, model, alpha, beta)
    }

    @Test func groupsSelectedAppsWithTheAppFirst() async throws {
        let (rig, model, _, _) = try rig()
        defer { withExtendedLifetime(rig) {} }
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let review = model.review()
        #expect(review.sections.map(\.app.displayName) == ["Alpha", "Beta"])
        let first = try #require(review.sections.first)
        #expect(first.rows.first?.isApp == true)
        #expect(first.rows.first?.title == "Application")
        #expect(first.rows.map(\.title).contains("Caches"))
        // The data folder is listed, unticked (never checked for you).
        let support = try #require(first.rows.first { $0.title == "Application support" })
        #expect(!support.isIncluded)
        #expect(support.disabledReason == nil)
        // Totals agree with the confirmation.
        #expect(review.selectedBytes == model.confirmation.totalBytes)
        #expect(review.selectedCount == model.confirmation.perApp.reduce(0) { $0 + $1.items + $1.dataItems })
    }

    @Test func disabledRowsSayWhy() async throws {
        let rig = try ModelRig()
        try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let lib = rig.environment.userLibrary
        let excluded = lib.appending(path: "Caches/com.test.alpha")
        try rig.file(excluded.appending(path: "c.bin"), bytes: 10)
        try rig.file(lib.appending(path: "Logs/com.test.alpha/l.log"), bytes: 10)
        let model = rig.uninstallerModel(
            protectedPaths: ProtectedPaths(environment: rig.environment, extraDenied: [excluded]))
        defer { withExtendedLifetime(rig) {} }
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        model.lockedFolders = [lib.appending(path: "Logs")]
        let rows = try #require(model.review().sections.first).rows
        #expect(rows.first { $0.url == excluded }?.disabledReason == "Excluded in Settings")
        #expect(rows.first { $0.title == "Logs" }?.disabledReason == "Needs Full Disk Access")
        #expect(rows.first { $0.title == "Logs" }?.isIncluded == false)
    }

    @Test func untickedFileNeverReachesTheCore() async throws {
        let (rig, model, alpha, _) = try rig()
        await model.load()
        let row = try #require(model.apps.first { $0.app.displayName == "Alpha" })
        model.selection = [row.app.url]
        let cache = try #require(model.review().sections.first?.rows.first { $0.title == "Caches" })
        let before = model.confirmation.totalBytes

        // The draft is the whole set left out: what was unticked already, plus the cache.
        model.applyReview(excluding: model.reviewExclusions.union([cache.url]), rows: Set(model.review().sections.flatMap(\.rows).map(\.url)))

        #expect(model.confirmation.totalBytes == before - cache.bytes)
        #expect(model.review().totals(excluding: model.reviewExclusions).bytes == model.confirmation.totalBytes)
        let records = await model.uninstallSelected(confirmed: model.confirmation, quit: FakeQuitter(running: FakeRunning()))
        #expect(!FileManager.default.fileExists(atPath: alpha.path))
        #expect(FileManager.default.fileExists(atPath: cache.url.path))
        // Never part of the plan: no move and no entry.
        let path = cache.url.path(percentEncoded: false)
        #expect(records.first?.entries.contains { $0.originalPath == path } == false)
        _ = rig
    }

    @Test func untickingTheAppDeselectsIt() async throws {
        let (rig, model, _, _) = try rig()
        defer { withExtendedLifetime(rig) {} }
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        let beta = try #require(model.review().sections.first { $0.app.displayName == "Beta" })
        let appRow = try #require(beta.rows.first)

        #expect(model.review().totals(excluding: [appRow.url]).sections[beta.id] == 0)
        model.applyReview(excluding: model.reviewExclusions.union([appRow.url]), rows: Set(model.review().sections.flatMap(\.rows).map(\.url)))

        #expect(!model.selection.contains(beta.id))
        #expect(model.review().sections.map(\.app.displayName) == ["Alpha"])
    }

    @Test func reTickingADataRowInReviewChecksIt() async throws {
        let (rig, model, _, _) = try rig()
        defer { withExtendedLifetime(rig) {} }
        await model.load()
        let alpha = try #require(model.apps.first { $0.app.displayName == "Alpha" })
        model.selection = [alpha.app.url]
        let support = try #require(model.review().sections.first?.rows.first { $0.title == "Application support" })
        var draft = model.reviewExclusions
        #expect(draft.contains(support.url))
        draft.remove(support.url)
        model.applyReview(excluding: draft, rows: Set(model.review().sections.flatMap(\.rows).map(\.url)))
        #expect(model.leftovers(for: alpha.app).first { $0.leftover.url == support.url }?.checked == true)
        #expect(model.confirmation.dataWarnings.count == 1)
    }

    // MARK: follow-ups

    @Test func uninstallUsesTheOneRuleForSkips() async throws {
        let rig = try ModelRig()
        try rig.makeApp("Alpha", bundleID: "com.test.alpha")
        let daemons = rig.environment.systemLibrary.appending(path: "LaunchDaemons")
        let plist = try rig.writeLaunchPlist(daemons, label: "com.test.alpha.daemon", program: "/x/y")
        let model = rig.uninstallerModel()
        model.canTakeOutOfTrash = true
        defer { withExtendedLifetime(rig) {} }
        await model.load()
        model.selection = Set(model.apps.map(\.app.url))
        // A helper-only item inside a locked folder: the rule says "needs the helper" first.
        model.lockedFolders = [daemons]
        let confirm = model.confirmation
        #expect(confirm.adminItems == 1)
        #expect(confirm.accessSkipped == 0)
        let records = await model.uninstallSelected(confirmed: confirm, quit: FakeQuitter(running: FakeRunning()))
        let path = plist.path(percentEncoded: false)
        #expect(records.first?.entries.first { $0.originalPath == path }?.outcome == .needsAdmin)
    }

    @Test func applyReviewChangesOnlyTheRowsItShowed() async throws {
        let (rig, model, _, _) = try rig()
        defer { withExtendedLifetime(rig) {} }
        await model.load()
        let alpha = try #require(model.apps.first { $0.app.displayName == "Alpha" })
        model.selection = [alpha.app.url]
        let review = model.review()
        let support = try #require(review.sections.first?.rows.first { $0.title == "Application support" })
        let cache = try #require(review.sections.first?.rows.first { $0.title == "Caches" })
        // The sheet showed every row except the data folder (e.g. it appeared after the sheet opened).
        let shown = Set(review.sections.flatMap(\.rows).map(\.url)).subtracting([support.url])

        model.applyReview(excluding: [cache.url], rows: shown)

        let rows = model.leftovers(for: alpha.app)
        #expect(rows.first { $0.id == cache.url }?.checked == false)
        // Not in the sheet: left as it was (unticked), even though the draft didn't exclude it.
        #expect(rows.first { $0.id == support.url }?.checked == false)
    }

    @Test func helperBlockReadsLikeTheRows() {
        #expect(LeftoverBlock.needsHelper.text == UninstallerScreen.helperNote)
    }

    @Test func dataRowsCarryTheirWarning() async throws {
        let (rig, model, _, _) = try rig()
        defer { withExtendedLifetime(rig) {} }
        await model.load()
        model.selection = Set(model.apps.filter { $0.app.displayName == "Alpha" }.map(\.app.url))
        let rows = try #require(model.review().sections.first).rows
        #expect(rows.first { $0.title == "Application support" }?.dataWarning?.hasPrefix("This is your data.") == true)
        #expect(rows.first { $0.title == "Caches" }?.dataWarning == nil)
    }
}
