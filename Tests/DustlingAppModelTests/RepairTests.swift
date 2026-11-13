import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// The three repair cases from SCREENS-final §8, the last run's problem rows, the retry plan and the
/// diagnostics report.
@MainActor
struct RepairTests {
    private let home = URL(filePath: "/Users/tester")
    private var environment: SystemEnvironment {
        SystemEnvironment(
            home: home, applicationDirectories: [], systemLibrary: URL(filePath: "/Library"),
            volumesDirectory: URL(filePath: "/Volumes"), userID: 501)
    }
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
            JournalEntry(originalPath: "/Library/Application Support/com.vendor.data", bytes: 5, outcome: .needsAdmin),
            JournalEntry(originalPath: caches.appending(path: "gone").path, bytes: 0,
                         outcome: .skipped(reason: "already gone")),
            JournalEntry(originalPath: "<history>", bytes: 0, outcome: .failed(reason: "disk full")),
        ])
    }

    private func appName(_ id: String) -> String? { id == "com.apple.mail" ? "Mail" : nil }

    // MARK: last run problems

    @Test func lastRunProblemsListOnlyWhatNeedsTheUser() {
        let problems = LastRunReview.problems(in: partialRun, environment: environment, fullDiskAccess: true, appName: appName)
        #expect(problems.map(\.result) == [.skipped, .skipped, .failed, .needsAdmin, .failed])
        #expect(problems[0].reason == "In use by Mail")
        #expect(problems[0].fix == .quitAndRetry(app: "Mail"))
        #expect(problems[0].display == "~/…/Mail Downloads/A1F2")
        #expect(problems[2].reason == "No access (Full Disk Access may be needed)")
        #expect(problems[2].fix == .retry)
        #expect(problems[3].reason == "Needs your Mac password")
        #expect(problems[3].fix == .retry)
        #expect(problems[3].display == "/Library/Application Support/com.vendor.data")
        // A history write failure is a problem too, but there is nothing to retry.
        #expect(problems[4].display == "Run history")
        #expect(problems[4].fix == nil)
    }

    @Test func protectedItemsHaveNoRetry() {
        let entry = JournalEntry(originalPath: caches.appending(path: "com.apple.textunderstandingd").path, bytes: 5,
                                 outcome: .failed(reason: "protected by macOS"))
        let review = run([entry])
        let problems = LastRunReview.problems(in: review, environment: environment, fullDiskAccess: true, appName: appName)
        #expect(problems.count == 1)
        #expect(problems[0].result == .failed)
        #expect(problems[0].reason == "Protected by macOS")
        #expect(problems[0].fix == nil)
        #expect(LastRunReview.retryableCount(in: review, environment: environment, fullDiskAccess: true) == 0)
    }

    @Test func systemCachesAndLogsAreNeverRetried() {
        // Dustling never cleans what macOS manages. A run from before that may still list System
        // caches and logs as needing the password: shown, never retried, whatever the catalog says.
        let system = JunkCategory(
            id: .systemCachesAndLogs, title: "System", selection: .preselected, requiresAdmin: true,
            roots: [URL(filePath: "/Library/Caches"), URL(filePath: "/Library/Logs")])
        let record = run([
            JournalEntry(originalPath: "/Library/Caches/com.apple.iconservices.store", bytes: 5, outcome: .needsAdmin),
            JournalEntry(originalPath: "/Library/Logs/install.log", bytes: 5, outcome: .failed(reason: "boom")),
            JournalEntry(originalPath: "/Library/Caches/com.x", bytes: 5,
                         outcome: .skipped(reason: ProtectedPaths.systemManagedReason)),
        ])
        let problems = LastRunReview.problems(in: record, environment: environment, fullDiskAccess: true, appName: appName)
        #expect(problems.map(\.fix) == [nil, nil])
        #expect(problems.first?.reason == "macOS manages it, so Dustling leaves it alone")
        #expect(LastRunReview.retryableCount(in: record, environment: environment, fullDiskAccess: true) == 0)
        #expect(LastRunReview.retryPlan(
            for: record, catalog: [cachesCategory, system], running: [], environment: environment, fullDiskAccess: true).urls.isEmpty)
    }

    @Test func theSystemsCachesAndLogsAreTheEnvironmentsNotFixedPaths() {
        // Which items are in the system's caches and logs comes from the environment's system Library.
        let elsewhere = SystemEnvironment(
            home: home, applicationDirectories: [], systemLibrary: URL(filePath: "/Volumes/Other/Library"),
            volumesDirectory: URL(filePath: "/Volumes"), userID: 501)
        let record = run([
            JournalEntry(originalPath: "/Volumes/Other/Library/Caches/com.x", bytes: 5, outcome: .needsAdmin),
            JournalEntry(originalPath: "/Library/Caches/com.y", bytes: 5, outcome: .needsAdmin),
        ])
        let problems = LastRunReview.problems(in: record, environment: elsewhere, fullDiskAccess: true, appName: appName)
        #expect(problems.map(\.reason) == ["macOS manages it, so Dustling leaves it alone", "Needs your Mac password"])
        #expect(problems.map(\.fix) == [nil, .retry])
        #expect(LastRunReview.retryableCount(in: record, environment: elsewhere, fullDiskAccess: true) == 1)
    }

    @Test func whatThePasswordCouldntDoHasNoRetry() {
        // macOS refused even with the password, the password step can't move it safely, or it is
        // kept in a hidden folder in /Library: trying again changes nothing, like "protected by macOS".
        let reasons = [
            AdminScript.refusedReason, AdminScript.unsafeReason, AdminScript.putBackUnsafeReason,
            AdminScript.heldReason(bridge: "/Library/.dustling-Ab12Cd34"),
            AdminScript.partlyDeletedReason(bridge: "/Library/.dustling-Ab12Cd34"),
        ]
        let review = run(reasons.enumerated().map { index, reason in
            JournalEntry(originalPath: "/Library/Caches/x\(index)", bytes: 5, outcome: .failed(reason: reason))
        })
        let problems = LastRunReview.problems(in: review, environment: environment, fullDiskAccess: true, appName: appName)
        #expect(problems.count == reasons.count)
        #expect(problems.allSatisfy { $0.result == .failed && $0.fix == nil })
        #expect(LastRunReview.retryableCount(in: review, environment: environment, fullDiskAccess: true) == 0)
        #expect(LastRunReview.retryPlan(
            for: review, catalog: [cachesCategory], running: [], environment: environment, fullDiskAccess: true).urls.isEmpty)
        // Any other failure can still be tried again.
        let other = run([JournalEntry(originalPath: caches.appending(path: "y").path, bytes: 5,
                                      outcome: .failed(reason: "Something else went wrong"))])
        #expect(LastRunReview.retryableCount(in: other, environment: environment, fullDiskAccess: true) == 1)
    }

    @Test func retryCountCoversInUseFailedAndNeedsAdminItemsOfACleanup() {
        #expect(LastRunReview.retryableCount(in: partialRun, environment: environment, fullDiskAccess: true) == 4)
        // Without Full Disk Access the password step can't run, so the needs-admin item waits.
        #expect(LastRunReview.retryableCount(in: partialRun, environment: environment, fullDiskAccess: false) == 3)
        let uninstall = run(partialRun.entries, kind: .uninstall(appName: "Zoom"))
        #expect(LastRunReview.retryableCount(in: uninstall, environment: environment, fullDiskAccess: true) == 0)
    }

    @Test func needsAdminProblemsCanBeRetried() {
        let rootOwned = caches.appending(path: "com.root.owned").path
        let alsoRootOwned = caches.appending(path: "com.root.other").path
        let record = run([
            JournalEntry(originalPath: rootOwned, bytes: 5, outcome: .needsAdmin),
            JournalEntry(originalPath: alsoRootOwned, bytes: 5, outcome: .needsAdmin),
        ])

        let problems = LastRunReview.problems(in: record, environment: environment, fullDiskAccess: true, appName: appName)
        #expect(problems.map(\.reason) == ["Needs your Mac password", "Needs your Mac password"])
        #expect(problems.map(\.fix) == [.retry, .retry])
        #expect(LastRunReview.retryableCount(in: record, environment: environment, fullDiskAccess: true) == 2)
        let plan = LastRunReview.retryPlan(for: record, catalog: [cachesCategory], running: [], environment: environment, fullDiskAccess: true)
        #expect(plan.urls.map(\.path) == [rootOwned, alsoRootOwned])
        #expect(plan.outsideCleanupArea == 0)

        // Without Full Disk Access, Dustling can't open the Trash for the password step: access first.
        let without = LastRunReview.problems(in: record, environment: environment, fullDiskAccess: false, appName: appName)
        #expect(without.map(\.reason) == Array(repeating: "Needs Full Disk Access, then your Mac password", count: 2))
        #expect(without.map(\.fix) == [nil, nil])
        #expect(LastRunReview.retryableCount(in: record, environment: environment, fullDiskAccess: false) == 0)
        #expect(LastRunReview.retryPlan(
            for: record, catalog: [cachesCategory], running: [], environment: environment, fullDiskAccess: false).urls.isEmpty)
        #expect(LastRunReview.summary(of: record, fullDiskAccess: true) == "2 need your Mac password")
        #expect(LastRunReview.summary(of: record, fullDiskAccess: false) == "2 need Full Disk Access, then your Mac password")

        // Only a cleanup is retried from Diagnostics.
        let uninstall = run(record.entries, kind: .uninstall(appName: "Zoom"))
        #expect(LastRunReview.problems(in: uninstall, environment: environment, fullDiskAccess: true, appName: appName)
            .map(\.fix) == [nil, nil])
    }

    @Test func lastRunLightOffersRetryWithTheCount() async {
        let record = partialRun
        let model = HealthModel(probe: { .granted }, clock: ManualClock(), lastRunSummary: { record })
        await model.refresh()
        let light = model.lights.first { $0.kind == .lastRun }
        #expect(light?.state == .warning)
        #expect(light?.fix == .retryItems(count: 4))
        #expect(light?.detail == "2 items in use, 2 failed, 1 needs your Mac password")
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
        let open = LastRunReview.retryPlan(for: partialRun, catalog: catalog, running: ["com.apple.mail"], environment: environment, fullDiskAccess: false)
        #expect(open.urls == [caches.appending(path: "com.locked")])
        #expect(open.stillOpen == ["com.apple.mail"])
        #expect(open.allowedRoots.map(\.path) == [caches.path])

        let closed = LastRunReview.retryPlan(for: partialRun, catalog: catalog, running: [], environment: environment, fullDiskAccess: false)
        #expect(closed.urls.count == 3)
        #expect(closed.stillOpen.isEmpty)
        #expect(Set(closed.allowedRoots.map(\.path)) == [caches.path, mailDownloads.path])

        // Nothing outside a junk folder is ever retried, whatever the journal says.
        let odd = run([JournalEntry(originalPath: "/Users/tester/Projects/app/build", bytes: 1, outcome: .failed(reason: "x"))])
        let plan = LastRunReview.retryPlan(for: odd, catalog: catalog, running: [], environment: environment, fullDiskAccess: true)
        #expect(plan.urls.isEmpty)
        #expect(plan.outsideCleanupArea == 1)
    }

    /// A retry wired like the app's, with a recorder for what would move.
    private final class RetryRig: @unchecked Sendable {
        nonisolated(unsafe) var ran: [URL]? = nil
        var completed = 0
        var gate = CleanupGate.make(canTakeOutOfTrash: true, policy: .warnBeforeCleaning)
        var skipping = CleanupSkip.none
        var busy = false
        var running: Set<String> = ["com.apple.mail"]
        var catalog: [JunkCategory]
        var fullDiskAccess = true
        /// What the run reports for each item.
        nonisolated(unsafe) var outcome = DeletionOutcome.movedToTrash(trashedPath: "/t")
    
        init(catalog: [JunkCategory]) { self.catalog = catalog }

        @MainActor func make(appName: @escaping (String) -> String?) -> LastRunRetry {
            LastRunRetry(
                catalog: { self.catalog }, running: { self.running }, appName: appName,
                gate: { self.gate }, skipping: { self.skipping }, isBusy: { self.busy },
                fullDiskAccess: { self.fullDiskAccess },
                environment: SystemEnvironment(
                    home: URL(filePath: "/Users/tester"), applicationDirectories: [], systemLibrary: URL(filePath: "/Library"),
                    volumesDirectory: URL(filePath: "/Volumes"), userID: 501),
                run: { [self] urls, _ in
                    self.ran = urls
                    return RunRecord(startedAt: Date(), kind: .junkClean, entries: urls.map {
                        JournalEntry(originalPath: $0.path, bytes: 1, outcome: self.outcome)
                    }, restorable: true)
                },
                onRunCompleted: { self.completed += 1 })
        }
    }

    private var cachesCategory: JunkCategory {
        JunkCategory(id: .userCaches, title: "C", selection: .preselected, requiresAdmin: false, roots: [caches])
    }

    private var mailCategory: JunkCategory {
        JunkCategory(id: .mailDownloads, title: "Mail", selection: .review, requiresAdmin: false, roots: [],
                     expansions: [RootExpansion(parent: home.appending(path: "Library/Containers"),
                                                subpath: "Data/Library/Mail Downloads")])
    }

    @Test func retryRunsThePlanAndReportsWhatHappened() async {
        let rig = RetryRig(catalog: [cachesCategory])
        let retry = rig.make(appName: appName)
        await retry.retry(partialRun)
        #expect(rig.ran == [caches.appending(path: "com.locked")])
        #expect(rig.completed == 1)
        #expect(retry.message == "Retried 1 item: 1 moved to the Trash. Mail is still open, so 2 items were left. Quit Mail, then retry.")
    }

    @Test func retryTriesNeedsAdminItemsAgainWithFullDiskAccess() async {
        let rootOwned = caches.appending(path: "com.root.owned")
        let record = run([JournalEntry(originalPath: rootOwned.path, bytes: 5, outcome: .needsAdmin)])
        let rig = RetryRig(catalog: [cachesCategory])
        rig.outcome = .needsAdmin   // the password box was closed again
        let retry = rig.make(appName: appName)
        await retry.retry(record)
        #expect(rig.ran == [rootOwned])
        #expect(retry.message == "Retried 1 item: 0 moved to the Trash, 1 needs your Mac password.")

        // Without Full Disk Access there is nothing a retry could do for it yet.
        let noAccess = RetryRig(catalog: [cachesCategory])
        noAccess.fullDiskAccess = false
        let refused = noAccess.make(appName: appName)
        await refused.retry(record)
        #expect(noAccess.ran == nil)
    }

    @Test func retryWithEveryItemStillOpenAsksToQuitFirst() async {
        let record = run([JournalEntry(originalPath: "/x/y", bytes: 1, outcome: .skipped(reason: "in use by com.apple.mail"))])
        let rig = RetryRig(catalog: [])
        let retry = rig.make(appName: appName)
        await retry.retry(record)
        #expect(rig.ran == nil)
        #expect(retry.message == "Mail is still open. Quit Mail, then retry.")
    }

    /// Limited mode: nothing moves until the user confirms the note; refused mode never moves.
    @Test func retryInLimitedModeNeedsConfirmation() async {
        let rig = RetryRig(catalog: [cachesCategory])
        rig.gate = CleanupGate.make(canTakeOutOfTrash: false, policy: .warnBeforeCleaning)
        let retry = rig.make(appName: appName)
        await retry.retry(partialRun)
        #expect(rig.ran == nil)
        #expect(retry.message == CleanupGate.limitedNote)
        await retry.retry(partialRun, confirmedLimited: true)
        #expect(rig.ran == [caches.appending(path: "com.locked")])

        let refused = RetryRig(catalog: [cachesCategory])
        refused.gate = CleanupGate.make(canTakeOutOfTrash: false, policy: .refuseToClean)
        let noRetry = refused.make(appName: appName)
        await noRetry.retry(partialRun, confirmedLimited: true)
        #expect(refused.ran == nil)
        #expect(noRetry.message == CleanupGate.refusedNote)
    }

    /// Places that can't be read now (Containers, Downloads without Full Disk Access) are left alone.
    @Test func retryLeavesLockedPlacesAlone() async {
        let downloads = home.appending(path: "Downloads")
        let rig = RetryRig(catalog: [cachesCategory, mailCategory,
                                     JunkCategory(id: .largeOldDownloads, title: "D", selection: .review,
                                                  requiresAdmin: false, roots: [downloads])])
        rig.running = []
        rig.skipping = CleanupSkip(categories: [.largeOldDownloads], folders: [home.appending(path: "Library/Containers")])
        let record = run([
            JournalEntry(originalPath: mailDownloads.appending(path: "A1F2").path, bytes: 1,
                         outcome: .skipped(reason: "in use by com.apple.mail")),
            JournalEntry(originalPath: downloads.appending(path: "big.dmg").path, bytes: 1, outcome: .failed(reason: "x")),
            JournalEntry(originalPath: caches.appending(path: "com.ok").path, bytes: 1, outcome: .failed(reason: "x")),
        ])
        let retry = rig.make(appName: appName)
        await retry.retry(record)
        #expect(rig.ran == [caches.appending(path: "com.ok")])
        #expect(retry.message?.contains("2 items are in places Dustling can't read without Full Disk Access") == true)
    }

    @Test func retryWaitsWhileBusyAndRefusesSampleData() async {
        let rig = RetryRig(catalog: [cachesCategory])
        rig.busy = true
        let retry = rig.make(appName: appName)
        await retry.retry(partialRun)
        #expect(rig.ran == nil)
        #expect(retry.message == "Wait until the current scan or cleanup finishes, then retry.")

        let sample = RetryRig(catalog: [cachesCategory])
        let sampleRetry = sample.make(appName: appName)
        sampleRetry.refusesSampleData = true
        await sampleRetry.retry(partialRun)
        #expect(sample.ran == nil)
        #expect(sample.completed == 0)
    }

    /// A failed item whose app is open now is left too, not only items skipped as in use.
    @Test func failedItemOfARunningAppIsLeft() {
        let record = run([JournalEntry(originalPath: caches.appending(path: "com.tinyspeck.slackmacgap").path,
                                       bytes: 1, outcome: .failed(reason: "x"))])
        let plan = LastRunReview.retryPlan(
            for: record, catalog: [cachesCategory], running: ["com.tinyspeck.slackmacgap"], environment: environment, fullDiskAccess: true)
        #expect(plan.urls.isEmpty)
        #expect(plan.stillOpen == ["com.tinyspeck.slackmacgap"])
    }

    /// The category's own filter (which carries recency and exclusions) is applied to every retry.
    @Test func retryReappliesTheCategoryFilter() {
        let picky = JunkCategory(id: .userCaches, title: "C", selection: .preselected, requiresAdmin: false,
                                 roots: [caches], itemFilter: { $0.lastPathComponent != "recent" })
        let record = run([
            JournalEntry(originalPath: caches.appending(path: "recent").path, bytes: 1, outcome: .failed(reason: "x")),
            JournalEntry(originalPath: caches.appending(path: "old").path, bytes: 1, outcome: .failed(reason: "x")),
        ])
        let plan = LastRunReview.retryPlan(for: record, catalog: [picky], running: [], environment: environment, fullDiskAccess: true)
        #expect(plan.urls == [caches.appending(path: "old")])
        #expect(plan.outsideCleanupArea == 1)
    }

    // MARK: repair cases and the blocker

    @Test func accessLostIsOnlyABlockerAfterItWasGranted() {
        let defaults = ScratchDefaults.make("dustling-memory")
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

    /// The DEBUG fixture's memory never reads or writes the saved value.
    @Test func sampleMemoryNeverSaves() {
        let defaults = ScratchDefaults.make("dustling-memory")
        let memory = FullDiskAccessMemory(defaults: defaults)
        memory.useSample(wasGranted: true)
        #expect(memory.isLost(.denied))
        memory.acknowledgeLoss()
        #expect(!memory.isLost(.denied))
        memory.observe(.granted)
        #expect(defaults.object(forKey: FullDiskAccessMemory.key) == nil)
    }

    @Test func lossCauseIsNewCopyWhenRequirementDiffers() {
        let defaults = ScratchDefaults.make("dustling-memory")
        FullDiskAccessMemory(defaults: defaults, currentRequirement: "req-A").observe(.granted)
        let other = FullDiskAccessMemory(defaults: defaults, currentRequirement: "req-B")
        #expect(other.lossCause(.denied) == .newCopy)
    }

    @Test func lossCauseIsTurnedOffForSameRequirement() {
        let defaults = ScratchDefaults.make("dustling-memory")
        FullDiskAccessMemory(defaults: defaults, currentRequirement: "req-A").observe(.granted)
        let same = FullDiskAccessMemory(defaults: defaults, currentRequirement: "req-A")
        #expect(same.lossCause(.denied) == .turnedOff)
    }

    @Test func legacyFlagWithoutRequirementIsUnknownCause() {
        let defaults = ScratchDefaults.make("dustling-memory")
        defaults.set(true, forKey: FullDiskAccessMemory.key)
        let memory = FullDiskAccessMemory(defaults: defaults, currentRequirement: "req-A")
        #expect(memory.lossCause(.denied) == .unknown)
    }

    @Test func noCauseWhenNeverGrantedOrGranted() {
        let defaults = ScratchDefaults.make("dustling-memory")
        let memory = FullDiskAccessMemory(defaults: defaults, currentRequirement: "req-A")
        #expect(memory.lossCause(.denied) == nil)
        memory.observe(.granted)
        #expect(memory.lossCause(.granted) == nil)
        #expect(memory.lossCause(.unknown) == nil)
    }

    @Test func nilRequirementStoresNothing() {
        let defaults = ScratchDefaults.make("dustling-memory")
        let memory = FullDiskAccessMemory(defaults: defaults, currentRequirement: nil)
        memory.observe(.granted)
        #expect(defaults.object(forKey: FullDiskAccessMemory.requirementKey) == nil)
        #expect(memory.lossCause(.denied) == .unknown)
    }

    @Test func acknowledgeClearsRequirement() {
        let defaults = ScratchDefaults.make("dustling-memory")
        let memory = FullDiskAccessMemory(defaults: defaults, currentRequirement: "req-A")
        memory.observe(.granted)
        #expect(defaults.string(forKey: FullDiskAccessMemory.requirementKey) == "req-A")
        memory.acknowledgeLoss()
        #expect(defaults.object(forKey: FullDiskAccessMemory.requirementKey) == nil)
        #expect(memory.lossCause(.denied) == nil)
    }

    @Test func sampleMemoryLossIsUnknownCause() {
        let defaults = ScratchDefaults.make("dustling-memory")
        let memory = FullDiskAccessMemory(defaults: defaults, currentRequirement: "req-A")
        memory.useSample(wasGranted: true)
        #expect(memory.lossCause(.denied) == .unknown)
        #expect(defaults.object(forKey: FullDiskAccessMemory.requirementKey) == nil)
    }

    @Test func lostCopyPerCause() {
        let newCopy = RepairCase.fullDiskAccessLostCopy(.newCopy)
        let off = RepairCase.fullDiskAccessLostCopy(.turnedOff)
        let unknown = RepairCase.fullDiskAccessLostCopy(.unknown)
        #expect(newCopy.title == "Turn Full Disk Access on for this copy")
        #expect(off.title == "Full Disk Access was turned off")
        #expect(unknown.title == "Full Disk Access was turned off")
        for c in [newCopy, off, unknown] { #expect(c.fix == "Open System Settings") }
        #expect(newCopy.why.contains("click −"))
        #expect(unknown.why.contains("click −"))
        #expect(!off.why.contains("click −"))
        #expect(RepairCase.fullDiskAccessLost.copy == unknown)
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
            JournalEntry(originalPath: home.appending(path: "Downloads/SecretPlan.zip").path, bytes: 1, outcome: .failed(
                reason: "\u{201C}SecretPlan.zip\u{201D} couldn\u{2019}t be moved to the trash because you don\u{2019}t have permission to access \u{201C}Downloads\u{201D}.")),
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
        #expect(!report.contains("SecretPlan"))
        #expect(!report.contains("Downloads"))
        #expect(!report.contains("\u{201C}"))
        #expect(report.contains("1 moved to the Trash, 1 skipped, 3 failed, 0 need admin rights"))
        #expect(report.contains("in use by com.apple.mail (1)"))
        #expect(report.contains("failed: other error (3)"))
        #expect(report.contains("No file names from your home folder are included."))

        // The same message from an Empty Trash run, plus a fixed reason that is kept.
        let empty = RunRecord(startedAt: Date(), kind: .emptyTrash, entries: [
            JournalEntry(originalPath: home.appending(path: ".Trash/SecretPlan.zip").path, bytes: 1, outcome: .failed(
                reason: "\u{201C}SecretPlan.zip\u{201D} couldn\u{2019}t be removed because you don\u{2019}t have permission to access it.")),
            JournalEntry(originalPath: home.appending(path: ".Trash/x").path, bytes: 1, outcome: .failed(reason: "Permission denied")),
        ], restorable: false)
        let emptyReport = DiagnosticsReport.make(DiagnosticsReport.Input(
            macOS: "macOS 26.1", appVersion: "0.1.0 (1)", checks: checks, lastRun: empty, home: home, generatedAt: Date()))
        #expect(!emptyReport.contains("SecretPlan"))
        #expect(!emptyReport.contains(home.path))
        #expect(emptyReport.contains("failed: other error (1)"))
        #expect(emptyReport.contains("failed: Permission denied (1)"))
    }

    @Test func diagnosticsReportKnowsTheProtectedAndPasswordReasons() {
        let reasons = [
            TrashMover.protectedReason, AdminScript.refusedReason, AdminScript.unsafeReason,
            AdminScript.putBackUnsafeReason, AdminScript.movedAwayReason, AdminScript.existsReason,
            AdminScript.noResultReason, OsascriptAdminShell.tooManyItemsReason, OsascriptAdminShell.stoppedReason,
            OsascriptAdminShell.passwordNotAcceptedReason, RunJournal.putBackNeedsPasswordReason,
        ]
        let record = run(reasons.enumerated().map { index, reason in
            JournalEntry(originalPath: home.appending(path: "Library/Caches/x\(index)").path, bytes: 1,
                         outcome: .failed(reason: reason))
        })
        let report = DiagnosticsReport.make(DiagnosticsReport.Input(
            macOS: "macOS 26.1", appVersion: "0.2.0 (1)", checks: [], lastRun: record, home: home, generatedAt: Date()))
        for reason in reasons { #expect(report.contains("failed: \(reason) (1)")) }
        #expect(!report.contains("other error"))
    }

    @Test func diagnosticsReportKnowsItemsKeptInLibraryWhateverTheFolder() {
        // The hidden folder's name changes with every password step: the reason is known by how it
        // starts, and reported (and counted) without the folder.
        let record = run([
            JournalEntry(originalPath: home.appending(path: "a").path, bytes: 1,
                         outcome: .failed(reason: AdminScript.heldReason(bridge: "/Library/.dustling-Ab12Cd34"))),
            JournalEntry(originalPath: home.appending(path: "b").path, bytes: 1,
                         outcome: .failed(reason: AdminScript.heldReason(bridge: "/Library/.dustling-Zz99Yy88"))),
            JournalEntry(originalPath: home.appending(path: "c").path, bytes: 1,
                         outcome: .failed(reason: AdminScript.partlyDeletedReason(bridge: "/Library/.dustling-Ab12Cd34"))),
        ], kind: .emptyTrash)
        let report = DiagnosticsReport.make(DiagnosticsReport.Input(
            macOS: "macOS 26.1", appVersion: "0.2.0 (1)", checks: [], lastRun: record, home: home, generatedAt: Date()))
        #expect(report.contains("failed: \(AdminScript.heldReason(bridge: nil)) (2)"))
        #expect(report.contains("failed: \(AdminScript.partlyDeletedReason(bridge: nil)) (1)"))
        #expect(!report.contains(".dustling-"))
        #expect(!report.contains("other error"))
    }

    @Test func helperCheckNoLongerSaysLaunchDaemonsStay() {
        // Uninstalling an app's launch daemon and cleaning system caches now move them with the
        // password; only switching system startup items waits for the helper.
        let checks = Diagnostics.checks(Diagnostics.Input(
            fullDiskAccess: .granted, published: true, checkedAt: nil, now: Date(), helper: .notAvailable,
            logFolder: .notCreatedYet, logFolderDisplay: "~/Library/Logs/Dustling"))
        #expect(checks.first { $0.kind == .helper }?.detail
            == "Coming in a later version. Until then, system startup items can't be turned on or off.")
    }
}
