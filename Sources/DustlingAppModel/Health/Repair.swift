import DustlingCore
import Foundation
import Observation

/// The three repair cases Dustling supports from day one (SCREENS-final §8), with the design's copy.
public enum RepairCase: Equatable, Sendable {
    /// Re-registering the helper failed and approval is needed in Login Items & Extensions. Reserved
    /// for the helper (Plan 2): in v1 the helper is "not available yet".
    case helperNotResponding
    /// A real read was denied after access had been on (another copy, or switched off).
    case fullDiskAccessLost
    /// The last cleanup left items in use or failed.
    case itemsDidNotMove(count: Int)

    public struct Copy: Equatable, Sendable {
        public let title: String
        public let why: String
        public let fix: String
    }

    /// Why Full Disk Access was lost, as far as Dustling can tell.
    /// `.unknown` is also what a Full Disk Access loss with no recorded cause shows.
    public static func fullDiskAccessLostCopy(_ cause: FullDiskAccessLoss) -> Copy {
        switch cause {
        case .newCopy:
            return Copy(
                title: "Turn Full Disk Access on for this copy",
                why: "macOS gives this permission to one exact copy of an app. This Dustling is a different copy (an update, or a second copy on this Mac), so macOS asks again. If System Settings already shows Dustling switched on, that's the other copy: select Dustling, click −, then drag this Dustling into the list.",
                fix: "Open System Settings")
        case .turnedOff:
            return Copy(
                title: "Full Disk Access was turned off",
                why: "Dustling is switched off under Full Disk Access in System Settings. Dustling noticed by trying a real read, so nothing was scanned with missing folders.",
                fix: "Open System Settings")
        case .unknown:
            return Copy(
                title: "Full Disk Access was turned off",
                why: "Full Disk Access is off for this copy of Dustling. If System Settings shows Dustling switched on, macOS is holding it for another copy: select Dustling, click −, then drag this Dustling into the list.",
                fix: "Open System Settings")
        }
    }

    public var copy: Copy {
        switch self {
        case .helperNotResponding:
            return Copy(
                title: "The cleanup helper isn't responding",
                why: "Dustling tried to register it again and that didn't work. System startup items can't be turned on or off until it's repaired.",
                fix: "Repair helper")
        case .fullDiskAccessLost:
            return Self.fullDiskAccessLostCopy(.unknown)
        case .itemsDidNotMove(let count):
            return Copy(
                title: "\(LastRunReview.items(count)) couldn't be moved",
                why: "Everything else is in the Trash. Each problem below has its reason and a fix, and the full log is saved.",
                fix: "Retry \(LastRunReview.items(count))")
        }
    }
}

/// Why Full Disk Access is gone: macOS holds it for a copy with a different code signature
/// requirement (`newCopy`), the same copy was switched off (`turnedOff`), or Dustling can't tell.
public enum FullDiskAccessLoss: Equatable, Sendable {
    case newCopy, turnedOff, unknown
}

/// Remembers, across launches, that Full Disk Access was on, and for which code requirement. Losing it
/// later is then a blocker before a scan, instead of a quietly smaller result. Someone who never
/// granted access is in limited mode and is never blocked.
@MainActor
public final class FullDiskAccessMemory {
    public static let key = "fullDiskAccessWasGranted"
    public static let requirementKey = "fullDiskAccessGrantedRequirement"
    private let defaults: UserDefaults
    private let currentRequirement: String?

    public init(
        defaults: UserDefaults = .standard,
        currentRequirement: String? = CodeIdentity.currentDesignatedRequirement()
    ) {
        self.defaults = defaults
        self.currentRequirement = currentRequirement
    }

    /// Set by the DEBUG fixture: the memory lives in this value only and nothing is saved.
    private var sample: Bool?

    public func observe(_ status: FullDiskAccessStatus) {
        guard status == .granted else { return }
        if sample != nil { sample = true; return }
        if !defaults.bool(forKey: Self.key) { defaults.set(true, forKey: Self.key) }
        if let currentRequirement, defaults.string(forKey: Self.requirementKey) != currentRequirement {
            defaults.set(currentRequirement, forKey: Self.requirementKey)
        }
    }

    /// Why access is lost now, or nil when it isn't.
    public func lossCause(_ status: FullDiskAccessStatus) -> FullDiskAccessLoss? {
        guard isLost(status) else { return nil }
        if sample != nil { return .unknown }
        guard let saved = defaults.string(forKey: Self.requirementKey), let currentRequirement else { return .unknown }
        return saved == currentRequirement ? .turnedOff : .newCopy
    }

    /// True when access was on before and a real read is denied now.
    public func isLost(_ status: FullDiskAccessStatus) -> Bool {
        status == .denied && (sample ?? defaults.bool(forKey: Self.key))
    }

    /// "Not now" on the blocker: Dustling continues in limited mode and says so in its banners.
    public func acknowledgeLoss() {
        if sample != nil { sample = false; return }
        defaults.set(false, forKey: Self.key)
        defaults.removeObject(forKey: Self.requirementKey)
    }

    /// For screenshots: pretend access was on, without reading or writing the saved value.
    public func useSample(wasGranted: Bool) {
        sample = wasGranted
    }
}

/// The last run's problems: what Diagnostics lists, what the light counts and what Retry tries again.
public enum LastRunReview {
    public struct Problem: Identifiable, Equatable, Sendable {
        public enum Result: Equatable, Sendable { case skipped, failed, needsAdmin }
        public enum Fix: Equatable, Sendable {
            /// The item was in use by this app.
            case quitAndRetry(app: String)
            case retry
        }

        public let id: Int
        /// The path as shown: home as `~`, long paths shortened in the middle.
        public let display: String
        public let result: Result
        public let reason: String
        /// nil when there is nothing the user can do now (a protected item, one macOS refused even with
        /// the password or that the password step can't move safely, one kept in a hidden folder in
        /// /Library, a history write, an item needing the password while Full Disk Access is off).
        public let fix: Fix?
    }

    /// The problem rows in journal order. Items skipped by choice (excluded, already gone, stopped)
    /// aren't problems and aren't listed. `fullDiskAccess`: whether Dustling has it now. An item
    /// needing admin rights moves with the Mac password then (retry); without it, access comes first.
    public static func problems(
        in run: RunRecord, home: URL, fullDiskAccess: Bool, appName: (String) -> String?
    ) -> [Problem] {
        let retryable = isRetryable(run.kind)
        return run.entries.enumerated().compactMap { index, entry in
            let display = displayPath(entry.originalPath, home: home)
            let fix: Problem.Fix? = retryable && isRetryableEntry(entry, fullDiskAccess: fullDiskAccess) ? .retry : nil
            switch entry.outcome {
            case .skipped(let reason):
                guard let bundleID = inUseBundleID(reason) else { return nil }
                let app = appName(bundleID) ?? bundleID
                return Problem(id: index, display: display, result: .skipped, reason: "In use by \(app)",
                               fix: retryable ? .quitAndRetry(app: app) : nil)
            case .failed(let reason):
                return Problem(id: index, display: display, result: .failed, reason: sentence(reason), fix: fix)
            case .needsAdmin:
                // An older run's System caches and logs: shown, never retried (Dustling leaves them alone).
                let reason = isSystemManaged(entry.originalPath)
                    ? ProtectedPaths.systemManagedReason : PasswordCopy.reason(fullDiskAccess: fullDiskAccess)
                return Problem(id: index, display: display, result: .needsAdmin, reason: reason, fix: fix)
            case .movedToTrash, .deleted:
                return nil
            }
        }
    }

    /// How many items "Retry N items" would try again: a cleanup's in-use and failed items, and with
    /// Full Disk Access those needing admin rights (the retry asks for the Mac password once).
    public static func retryableCount(in run: RunRecord, fullDiskAccess: Bool) -> Int {
        guard isRetryable(run.kind) else { return 0 }
        return run.entries.filter { isRetryableEntry($0, fullDiskAccess: fullDiskAccess) }.count
    }

    /// "2 items in use, 2 failed, 1 needs your Mac password", or nil when the run had no problems.
    public static func summary(of run: RunRecord, fullDiskAccess: Bool) -> String? {
        let inUse = run.entries.filter { if case .skipped(let r) = $0.outcome { inUseBundleID(r) != nil } else { false } }.count
        let failed = run.failedCount
        let admin = run.needsAdminCount
        var parts: [String] = []
        if inUse > 0 { parts.append("\(items(inUse)) in use") }
        if failed > 0 { parts.append("\(failed) failed") }
        if admin > 0 { parts.append(PasswordCopy.count(admin, fullDiskAccess: fullDiskAccess)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// What a retry may do. Items of apps that are open now are left (they would be in use again),
    /// items in places that can't be read now are left (as a cleanup does), and nothing outside a junk
    /// category's own folders, or that its category wouldn't pick today (filters, recency, exclusions),
    /// is ever retried, whatever the journal says.
    public struct RetryPlan: Equatable, Sendable {
        public var urls: [URL] = []
        public var allowedRoots: [URL] = []
        /// Bundle IDs of apps open now, in the order first seen.
        public var stillOpen: [String] = []
        /// Items left out because they aren't (or no longer) junk in a folder Dustling cleans.
        public var outsideCleanupArea = 0
        /// Items left because their app is open now.
        public var leftOpen = 0
        /// Items left because their place can't be read now (limited mode).
        public var lockedPlaces = 0
    }

    /// `catalog` should be the categories the places check allows right now
    /// (`HomeMosaic.scannable`), and `skipping` what a cleanup would leave alone now. With
    /// `fullDiskAccess`, items that needed admin rights are tried again too (the run asks for the Mac
    /// password once). Never what is in System caches and logs, which Dustling never cleans (an older
    /// run may list it).
    public static func retryPlan(
        for run: RunRecord, catalog: [JunkCategory], running: Set<String>, skipping: CleanupSkip = .none,
        fullDiskAccess: Bool
    ) -> RetryPlan {
        var plan = RetryPlan()
        guard isRetryable(run.kind) else { return plan }
        // System caches and logs are never cleaned, so never retried.
        let catalog = catalog.filter { !$0.isNeverCleaned }
        for entry in run.entries where isRetryableEntry(entry, fullDiskAccess: fullDiskAccess) {
            let url = URL(filePath: entry.originalPath)
            var owner: String?
            if case .skipped(let reason) = entry.outcome, let id = inUseBundleID(reason), running.contains(id) {
                owner = id
            } else {
                let id = JunkCatalog.ownerBundleID(of: url)
                if running.contains(id) { owner = id }
            }
            if let owner {
                if !plan.stillOpen.contains(owner) { plan.stillOpen.append(owner) }
                plan.leftOpen += 1
                continue
            }
            let parent = url.deletingLastPathComponent()
            let candidates = catalog.filter { $0.isDeclaredRoot(parent) }
            // Text only first: a place that can't be read now is never looked at.
            if candidates.contains(where: { skipping.skips(url, category: $0.id) }) {
                plan.lockedPlaces += 1
                continue
            }
            guard candidates.contains(where: { $0.itemFilter(url) }) else {
                plan.outsideCleanupArea += 1
                continue
            }
            plan.urls.append(url)
            if !plan.allowedRoots.contains(parent) { plan.allowedRoots.append(parent) }
        }
        return plan
    }

    // MARK: Helpers

    static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    private static func isRetryable(_ kind: RunKind) -> Bool { kind == .junkClean }

    private static func isRetryableEntry(_ entry: JournalEntry, fullDiskAccess: Bool) -> Bool {
        if isSystemManaged(entry.originalPath) { return false }
        switch entry.outcome {
        case .skipped(let reason): return inUseBundleID(reason) != nil
        case .failed(let reason): return !entry.originalPath.hasPrefix("<") && !isFinal(reason)
        case .needsAdmin: return fullDiskAccess
        case .movedToTrash, .deleted: return false
        }
    }

    /// In the system's caches or logs (`/Library/Caches`, `/Library/Logs`): macOS manages what is
    /// there, and Dustling never cleans it (`JunkCategory.isNeverCleaned`). Runs from before that
    /// may still list such items; they are shown, never retried.
    static func isSystemManaged(_ path: String) -> Bool {
        ["/Library/Caches/", "/Library/Logs/"].contains { path.hasPrefix($0) }
    }

    /// Failures a retry can't change: macOS protects the item, macOS refused even with the
    /// password, the password step can't do it safely, or the item is kept in a hidden folder in
    /// /Library (no longer where a retry would look).
    private static func isFinal(_ reason: String) -> Bool {
        [TrashMover.protectedReason, AdminScript.refusedReason, AdminScript.unsafeReason,
         AdminScript.putBackUnsafeReason].contains(reason) || AdminScript.isKeptAside(reason)
    }

    static func inUseBundleID(_ reason: String) -> String? {
        let prefix = "in use by "
        guard reason.hasPrefix(prefix) else { return nil }
        let id = String(reason.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// `~/…/Mail Downloads/A1F2`: the home folder as `~`, and paths deeper than four parts keep only
    /// their last two. `<history>` and `<log>` read as "Run history" and "Log file".
    static func displayPath(_ path: String, home: URL) -> String {
        if path == "<history>" { return "Run history" }
        if path == "<log>" { return "Log file" }
        let short = AppSettings.tilde(path, home: home)
        let parts = short.split(separator: "/", omittingEmptySubsequences: true)
        let underHome = short.hasPrefix("~")
        guard underHome, parts.count > 4 else { return short }
        return "~/…/" + parts.suffix(2).joined(separator: "/")
    }
}

/// "Retry N items": tries the last cleanup's in-use and failed items again through the same runner
/// (and so the same protected paths and exclusions) as every cleanup, behind the same gate: in limited
/// mode it asks first (or refuses), and places that can't be read now are left alone. With Full Disk
/// Access (`fullDiskAccess`) the items that needed admin rights are tried again too; the app's `run`
/// then asks for the Mac password once for them.
@MainActor @Observable
public final class LastRunRetry {
    public private(set) var isRetrying = false
    /// What happened, in plain words, after the last retry.
    public private(set) var message: String?
    #if DEBUG
    /// DEBUG screenshot fixtures show sample runs; retrying them would write to the real history.
    public var refusesSampleData = false

    /// Screenshot fixture: a retry is running (it never finishes; nothing is retried).
    public func showFixtureRetrying() {
        guard refusesSampleData else { return }
        isRetrying = true
    }
    #endif

    @ObservationIgnored private let catalog: () -> [JunkCategory]
    @ObservationIgnored private let running: () -> Set<String>
    @ObservationIgnored private let appName: (String) -> String?
    @ObservationIgnored private let gate: () -> CleanupGate
    @ObservationIgnored private let skipping: () -> CleanupSkip
    @ObservationIgnored private let isBusy: () -> Bool
    @ObservationIgnored private let fullDiskAccess: () -> Bool
    @ObservationIgnored private let run: @Sendable ([URL], [URL]) async -> RunRecord
    @ObservationIgnored private let onRunCompleted: () -> Void

    public init(
        catalog: @escaping () -> [JunkCategory],
        running: @escaping () -> Set<String>,
        appName: @escaping (String) -> String?,
        gate: @escaping () -> CleanupGate,
        skipping: @escaping () -> CleanupSkip,
        isBusy: @escaping () -> Bool,
        fullDiskAccess: @escaping () -> Bool,
        run: @escaping @Sendable ([URL], [URL]) async -> RunRecord,
        onRunCompleted: @escaping () -> Void
    ) {
        self.catalog = catalog
        self.running = running
        self.appName = appName
        self.gate = gate
        self.skipping = skipping
        self.isBusy = isBusy
        self.fullDiskAccess = fullDiskAccess
        self.run = run
        self.onRunCompleted = onRunCompleted
    }

    /// The gate the button checks before asking for confirmation in limited mode.
    public var currentGate: CleanupGate { gate() }

    /// `confirmedLimited`: the user confirmed the limited-mode note (no Put back without access).
    public func retry(_ record: RunRecord, confirmedLimited: Bool = false) async {
        guard !isRetrying else { return }
        #if DEBUG
        if refusesSampleData {
            message = "These are sample items, so nothing was retried."
            return
        }
        #endif
        if isBusy() {
            message = "Wait until the current scan or cleanup finishes, then retry."
            return
        }
        let gate = self.gate()
        switch gate.kind {
        case .refused:
            message = gate.note
            return
        case .confirmFirst where !confirmedLimited:
            message = gate.note
            return
        case .allowed, .confirmFirst:
            break
        }
        let plan = LastRunReview.retryPlan(
            for: record, catalog: catalog(), running: running(), skipping: skipping(), fullDiskAccess: fullDiskAccess())
        let open = plan.stillOpen.map { appName($0) ?? $0 }
        let openList = ListFormatter.localizedString(byJoining: open)
        var notes: [String] = []
        if !open.isEmpty {
            notes.append("\(openList) \(open.count == 1 ? "is" : "are") still open, so \(LastRunReview.items(plan.leftOpen)) "
                + "\(plan.leftOpen == 1 ? "was" : "were") left. Quit \(openList), then retry.")
        }
        if plan.lockedPlaces > 0 {
            notes.append("\(LastRunReview.items(plan.lockedPlaces)) \(plan.lockedPlaces == 1 ? "is" : "are") in places "
                + "Dustling can't read without Full Disk Access, so \(plan.lockedPlaces == 1 ? "it was" : "they were") left.")
        }
        guard !plan.urls.isEmpty else {
            if notes.isEmpty {
                message = "Nothing could be retried. Those items aren't junk in a folder Dustling cleans."
            } else if plan.lockedPlaces == 0, !open.isEmpty {
                message = "\(openList) \(open.count == 1 ? "is" : "are") still open. Quit \(openList), then retry."
            } else {
                message = "Nothing was retried. " + notes.joined(separator: " ")
            }
            return
        }
        isRetrying = true
        message = nil
        let result = await run(plan.urls, plan.allowedRoots)
        isRetrying = false
        let moved = result.entries.filter { if case .movedToTrash = $0.outcome { true } else { false } }.count
        var parts = ["\(moved) moved to the Trash"]
        if result.skippedCount > 0 { parts.append("\(result.skippedCount) skipped") }
        if result.failedCount > 0 { parts.append("\(result.failedCount) failed") }
        if result.needsAdminCount > 0 {
            parts.append(PasswordCopy.count(result.needsAdminCount, fullDiskAccess: fullDiskAccess()))
        }
        message = (["Retried \(LastRunReview.items(plan.urls.count)): " + parts.joined(separator: ", ") + "."] + notes)
            .joined(separator: " ")
        onRunCompleted()
    }
}
