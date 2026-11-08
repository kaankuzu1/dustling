import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// The three repair cases from SCREENS-final §8, the last run's problem rows, the retry plan and the
/// diagnostics report.
@MainActor
struct RepairTests {
    private let home = URL(filePath: "/Users/tester")
    private var caches: URL { home.appending(path: "Library/Caches") }
    private var mailDownloads: URL {
        home.appending(path: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
    }

    private func run(_ entries: [JournalEntry], kind: RunKind = .junkClean) -> RunRecord {
        RunRecord(startedAt: Date(timeIntervalSince1970: 1_800_000_000), kind: kind, entries: entries, restorable: true)
    }

    private func moved(_ path: String, bytes: UInt64 = 10) -> JournalEntry {
        JournalEntry(originalPath: path, bytes: bytes, outcome: .movedToTrash(trashedPath: "/Users/tester/.Trash/x"))
    }

    private var partialRun: RunRecord {
        run([
            moved(caches.appending(path: "Homebrew").path),
            JournalEntry(originalPath: mailDownloads.appending(path: "A1F2").path, bytes: 5,
                         outcome: .skipped(reason: "in use by com.apple.mail")),
            JournalEntry(originalPath: mailDownloads.appending(path: "7C09").path, bytes: 5,
                         outcome: .skipped(reason: "in use by com.apple.mail")),
            JournalEntry(originalPath: caches.appending(path: "com.locked").path, bytes: 5,
                         outcome: .failed(reason: "no access (Full Disk Access may be needed)")),
            JournalEntry(originalPath: "/Library/Caches/com.apple.iconservices.store", bytes: 5, outcome: .needsAdmin),
            JournalEntry(originalPath: caches.appending(path: "gone").path, bytes: 0,
                         outcome: .skipped(reason: "already gone")),
            JournalEntry(originalPath: "<history>", bytes: 0, outcome: .failed(reason: "disk full")),
        ])
    }

    private func appName(_ id: String) -> String? { id == "com.apple.mail" ? "Mail" : nil }

    // MARK: last run problems

    @Test func lastRunProblemsListOnlyWhatNeedsTheUser() {
        let problems = LastRunReview.problems(in: partialRun, home: home, appName: appName)
        #expect(problems.map(\.result) == [.skipped, .skipped, .failed, .needsAdmin, .failed])
        #expect(problems[0].reason == "In use by Mail")
        #expect(problems[0].fix == .quitAndRetry(app: "Mail"))
        #expect(problems[0].display == "~/…/Mail Downloads/A1F2")
        #expect(problems[2].reason == "No access (Full Disk Access may be needed)")
        #expect(problems[2].fix == .retry)
        #expect(problems[3].reason == "Needs the cleanup helper (coming in a later version)")
        #expect(problems[3].fix == nil)
        #expect(problems[3].display == "/Library/Caches/com.apple.iconservices.store")
        // A history write failure is a problem too, but there is nothing to retry.
        #expect(problems[4].display == "Run history")
        #expect(problems[4].fix == nil)
    }

    @Test func retryCountCoversInUseAndFailedItemsOfACleanup() {
        #expect(LastRunReview.retryableCount(in: partialRun) == 3)
        let uninstall = run(partialRun.entries, kind: .uninstall(appName: "Zoom"))
        #expect(LastRunReview.retryableCount(in: uninstall) == 0)
    }

    @Test func lastRunLightOffersRetryWithTheCount() async {
        let record = partialRun
        let model = HealthModel(probe: { .granted }, clock: ManualClock(), lastRunSummary: { record })
        await model.refresh()
        let light = model.lights.first { $0.kind == .lastRun }
        #expect(light?.state == .warning)
        #expect(light?.fix == .retryItems(count: 3))
        #expect(light?.detail == "2 items in use, 2 failed, 1 needs admin rights")
        #expect(model.lastRun == record)
    }

    @Test func runWithOnlySkippedByChoiceIsFine() async {
        let record = run([moved("/a"), JournalEntry(originalPath: "/b", bytes: 1, outcome: .skipped(reason: "excluded in Settings"))])
        let model = HealthModel(probe: { .granted }, clock: ManualClock(), lastRunSummary: { record })
        await model.refresh()
        #expect(model.lights.first { $0.kind == .lastRun }?.state == .ok)
        #expect(model.lastRunProblem == nil)
    }

    // MARK: retry plan

    @Test func retryPlanKeepsOpenAppsItemsAndStaysInsideCleanupFolders() {
        let containers = home.appending(path: "Library/Containers")
        let catalog = [
            JunkCategory(id: .userCaches, title: "Caches", selection: .preselected, requiresAdmin: false, roots: [caches]),
            JunkCategory(id: .mailDownloads, title: "Mail", selection: .review, requiresAdmin: false, roots: [],
                         expansions: [RootExpansion(parent: containers, subpath: "Data/Library/Mail Downloads")]),
        ]
        let open = LastRunReview.retryPlan(for: partialRun, catalog: catalog, running: ["com.apple.mail"])
        #expect(open.urls == [caches.appending(path: "com.locked")])
        #expect(open.stillOpen == ["com.apple.mail"])
        #expect(open.allowedRoots.map(\.path) == [caches.path])

        let closed = LastRunReview.retryPlan(for: partialRun, catalog: catalog, running: [])
        #expect(closed.urls.count == 3)
        #expect(closed.stillOpen.isEmpty)
        #expect(Set(closed.allowedRoots.map(\.path)) == [caches.path, mailDownloads.path])

        // Nothing outside a junk folder is ever retried, whatever the journal says.
        let odd = run([JournalEntry(originalPath: "/Users/tester/Projects/app/build", bytes: 1, outcome: .failed(reason: "x"))])
        let plan = LastRunReview.retryPlan(for: odd, catalog: catalog, running: [])
        #expect(plan.urls.isEmpty)
        #expect(plan.outsideCleanupArea == 1)
    }

    @Test func retryRunsThePlanAndReportsWhatHappened() async {
        let record = partialRun
        nonisolated(unsafe) var ran: [URL] = []
        var completed = 0
        let retry = LastRunRetry(
            catalog: { [JunkCategory(id: .userCaches, title: "C", selection: .preselected, requiresAdmin: false, roots: [self.caches])] },
            running: { ["com.apple.mail"] },
            appName: appName,
            run: { urls, _ in
                ran = urls
                return RunRecord(startedAt: Date(), kind: .junkClean, entries: urls.map {
                    JournalEntry(originalPath: $0.path, bytes: 1, outcome: .movedToTrash(trashedPath: "/t"))
                }, restorable: true)
            },
            onRunCompleted: { completed += 1 })
        await retry.retry(record)
        #expect(ran == [caches.appending(path: "com.locked")])
        #expect(completed == 1)
        #expect(retry.message == "Retried 1 item: 1 moved to the Trash. Mail is still open, so 2 items were left. Quit Mail, then retry.")
    }

    @Test func retryWithEveryItemStillOpenAsksToQuitFirst() async {
        let record = run([JournalEntry(originalPath: "/x/y", bytes: 1, outcome: .skipped(reason: "in use by com.apple.mail"))])
        nonisolated(unsafe) var ran = false
        let retry = LastRunRetry(
            catalog: { [] }, running: { ["com.apple.mail"] }, appName: appName,
            run: { _, _ in ran = true; return record }, onRunCompleted: {})
        await retry.retry(record)
        #expect(!ran)
        #expect(retry.message == "Mail is still open. Quit Mail, then retry.")
    }

    // MARK: repair cases and the blocker

    @Test func accessLostIsOnlyABlockerAfterItWasGranted() {
        let defaults = UserDefaults(suiteName: "dustling-memory-\(UUID().uuidString)")!
        let memory = FullDiskAccessMemory(defaults: defaults)
        #expect(!memory.isLost(.denied))
        memory.observe(.granted)
        #expect(!memory.isLost(.granted))
        #expect(memory.isLost(.denied))
        #expect(!memory.isLost(.unknown))
        // Remembered across launches: an ad-hoc rebuild drops access between runs.
        #expect(FullDiskAccessMemory(defaults: defaults).isLost(.denied))
        memory.acknowledgeLoss()
        #expect(!FullDiskAccessMemory(defaults: defaults).isLost(.denied))
    }

    @Test func repairCasesHaveTheDesignCopy() {
        let fda = RepairCase.fullDiskAccessLost.copy
        #expect(fda.title == "Full Disk Access was turned off")
        #expect(fda.fix == "Open System Settings")
        let results = RepairCase.itemsDidNotMove(count: 2).copy
        #expect(results.title == "2 items couldn't be moved")
        #expect(results.fix == "Retry 2 items")
        #expect(RepairCase.itemsDidNotMove(count: 1).copy.fix == "Retry 1 item")
        #expect(RepairCase.helperNotResponding.copy.fix == "Repair helper")
        for c in [fda, results, RepairCase.helperNotResponding.copy] {
            #expect(!c.why.contains("—"))
            #expect(!c.why.contains("!"))
        }
    }

    @Test func helperRepairIsNotAvailableYetInVersionOne() {
        let checks = Diagnostics.checks(Diagnostics.Input(
            fullDiskAccess: .granted, published: true, checkedAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 120), helper: .notAvailable, logFolder: .ready(bytes: 2_100_000),
            logFolderDisplay: "~/Library/Logs/Dustling"))
        let helper = checks.first { $0.kind == .helper }
        #expect(helper?.chip == "Not available yet")
        #expect(helper?.state == .info)
        #expect(helper?.repair == nil)
        let fda = checks.first { $0.kind == .fullDiskAccess }
        #expect(fda?.detail == "Checked 2 minutes ago by reading a protected folder")
        #expect(fda?.chip == "OK")
        #expect(checks.first { $0.kind == .logFolder }?.detail == "~/Library/Logs/Dustling, 2.1 MB")
    }

    @Test func lostAccessCheckOffersSystemSettings() {
        let checks = Diagnostics.checks(Diagnostics.Input(
            fullDiskAccess: .denied, published: true, checkedAt: Date(), now: Date(), helper: .notResponding,
            logFolder: .notCreatedYet, logFolderDisplay: "~/Library/Logs/Dustling"))
        let fda = checks.first { $0.kind == .fullDiskAccess }
        #expect(fda?.detail == "Denied when reading a protected folder")
        #expect(fda?.chip == "Needs repair")
        #expect(fda?.repair == .openFullDiskAccessSettings)
        // Reserved for the helper (Plan 2): the repair exists in the model already.
        #expect(checks.first { $0.kind == .helper }?.repair == .repairHelper)
        #expect(checks.first { $0.kind == .logFolder }?.detail == "~/Library/Logs/Dustling, created with the first run")
    }

    @Test func checkedAgoWording() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(Diagnostics.checkedAgo(now, now: now) == "Checked just now")
        #expect(Diagnostics.checkedAgo(now.addingTimeInterval(-60), now: now) == "Checked 1 minute ago")
        #expect(Diagnostics.checkedAgo(now.addingTimeInterval(-300), now: now) == "Checked 5 minutes ago")
        #expect(Diagnostics.checkedAgo(now.addingTimeInterval(-7200), now: now) == "Checked 2 hours ago")
    }

    // MARK: diagnostics report

    @Test func diagnosticsReportHasNoHomePaths() {
        let secret = home.appending(path: "Documents/SecretProject-Invoice.pdf").path
        let record = run([
            moved(home.appending(path: "Library/Caches/SecretCacheName").path),
            JournalEntry(originalPath: secret, bytes: 1, outcome: .failed(reason: "couldn't move \(secret): permission denied")),
            JournalEntry(originalPath: mailDownloads.appending(path: "A1F2").path, bytes: 1,
                         outcome: .skipped(reason: "in use by com.apple.mail")),
            JournalEntry(originalPath: "<log>", bytes: 0, outcome: .failed(reason: "\(home.path)/Library/Logs/Dustling is read-only")),
        ])
        let checks = Diagnostics.checks(Diagnostics.Input(
            fullDiskAccess: .denied, published: true, checkedAt: Date(), now: Date(), helper: .notAvailable,
            logFolder: .ready(bytes: 1000), logFolderDisplay: "\(home.path)/Library/Logs/Dustling"))
        let report = DiagnosticsReport.make(DiagnosticsReport.Input(
            macOS: "macOS 26.1 (25B78)", appVersion: "0.1.0 (1)", checks: checks, lastRun: record, home: home,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000)))

        #expect(!report.contains(home.path))
        #expect(!report.contains("tester"))
        #expect(!report.contains("~/"))
        #expect(!report.contains("SecretProject"))
        #expect(!report.contains("SecretCacheName"))
        #expect(!report.contains("Mail Downloads"))
        // What it does contain.
        #expect(report.contains("macOS 26.1 (25B78)"))
        #expect(report.contains("Dustling 0.1.0 (1)"))
        #expect(report.contains("Full Disk Access: Needs repair"))
        #expect(report.contains("Cleanup helper: Not available yet"))
        #expect(report.contains("1 moved to the Trash, 1 skipped, 2 failed, 0 need admin rights"))
        #expect(report.contains("in use by com.apple.mail (1)"))
        #expect(report.contains("No file names from your home folder are included."))
    }
}
