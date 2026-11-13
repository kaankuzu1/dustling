import DustlingCore
import Foundation

/// The Diagnostics page's checks (SCREENS-final §8): each with its last result and a repair where
/// one can work. Settings > Permissions and helper shows the same rows.
public enum Diagnostics {
    public enum LogFolderState: Equatable, Sendable {
        case ready(bytes: UInt64)
        /// The folder appears with the first run's log.
        case notCreatedYet
        case notWritable
    }

    public struct Check: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case fullDiskAccess, helper, logFolder }
        public enum State: Equatable, Sendable { case ok, warning, info, checking }

        public var id: Kind { kind }
        public let kind: Kind
        public let title: String
        public let detail: String
        public let state: State
        public let chip: String
        public let repair: FixAction?
    }

    public struct Input: Sendable {
        public var fullDiskAccess: FullDiskAccessStatus
        public var published: Bool
        public var checkedAt: Date?
        public var now: Date
        public var helper: HelperStatus
        public var logFolder: LogFolderState
        /// The log folder as shown in the app (`~/Library/Logs/Dustling`). Never in the report.
        public var logFolderDisplay: String

        public init(
            fullDiskAccess: FullDiskAccessStatus, published: Bool, checkedAt: Date?, now: Date,
            helper: HelperStatus, logFolder: LogFolderState, logFolderDisplay: String
        ) {
            self.fullDiskAccess = fullDiskAccess
            self.published = published
            self.checkedAt = checkedAt
            self.now = now
            self.helper = helper
            self.logFolder = logFolder
            self.logFolderDisplay = logFolderDisplay
        }
    }

    public static func checks(_ input: Input) -> [Check] {
        [fullDiskAccess(input), helper(input.helper), logFolder(input)]
    }

    /// True when every check is OK or only "not available yet".
    public static func allWorking(_ checks: [Check]) -> Bool {
        checks.allSatisfy { $0.state == .ok || $0.state == .info }
    }

    private static func fullDiskAccess(_ input: Input) -> Check {
        let title = "Full Disk Access"
        guard input.published else {
            return Check(kind: .fullDiskAccess, title: title, detail: "Checking by reading a protected folder",
                         state: .checking, chip: "Checking", repair: nil)
        }
        switch input.fullDiskAccess {
        case .granted:
            let when = input.checkedAt.map { checkedAgo($0, now: input.now) } ?? "Checked"
            return Check(kind: .fullDiskAccess, title: title, detail: "\(when) by reading a protected folder",
                         state: .ok, chip: "OK", repair: nil)
        case .denied:
            return Check(kind: .fullDiskAccess, title: title, detail: "Denied when reading a protected folder",
                         state: .warning, chip: "Needs repair", repair: .openFullDiskAccessSettings)
        case .unknown:
            return Check(kind: .fullDiskAccess, title: title,
                         detail: "Reading a protected folder gave no clear answer",
                         state: .warning, chip: "Needs repair", repair: .openFullDiskAccessSettings)
        }
    }

    private static func helper(_ status: HelperStatus) -> Check {
        let title = "Cleanup helper"
        switch status {
        case .notAvailable:
            return Check(kind: .helper, title: title,
                         detail: "Coming in a later version. Until then, system startup items can't be turned on or off.",
                         state: .info, chip: "Not available yet", repair: nil)
        case .ok:
            return Check(kind: .helper, title: title, detail: "Registered and responding", state: .ok, chip: "OK", repair: nil)
        case .needsApproval:
            return Check(kind: .helper, title: title, detail: "Needs your approval in Login Items & Extensions",
                         state: .warning, chip: "Needs repair", repair: .repairHelper)
        case .notResponding:
            return Check(kind: .helper, title: title, detail: "Not responding. Re-registering failed",
                         state: .warning, chip: "Needs repair", repair: .repairHelper)
        }
    }

    private static func logFolder(_ input: Input) -> Check {
        let title = "Log folder"
        switch input.logFolder {
        case .ready(let bytes):
            return Check(kind: .logFolder, title: title, detail: "\(input.logFolderDisplay), \(Bytes.format(Int64(clamping: bytes)))",
                         state: .ok, chip: "OK", repair: nil)
        case .notCreatedYet:
            return Check(kind: .logFolder, title: title, detail: "\(input.logFolderDisplay), created with the first run",
                         state: .ok, chip: "OK", repair: nil)
        case .notWritable:
            return Check(kind: .logFolder, title: title, detail: "Dustling can't write to \(input.logFolderDisplay)",
                         state: .warning, chip: "Needs repair", repair: nil)
        }
    }

    /// "Checked just now", "Checked 1 minute ago", "Checked 5 minutes ago", "Checked 2 hours ago".
    public static func checkedAgo(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Checked just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "Checked \(minutes) \(minutes == 1 ? "minute" : "minutes") ago" }
        let hours = minutes / 60
        if hours < 24 { return "Checked \(hours) \(hours == 1 ? "hour" : "hours") ago" }
        let days = hours / 24
        return "Checked \(days) \(days == 1 ? "day" : "days") ago"
    }

    /// `readLogFolder` off the main actor.
    public static func readLogFolderInBackground(_ folder: URL) async -> LogFolderState {
        await Blocking.run { readLogFolder(folder) }
    }

    /// The log folder's size and state, read from disk. Missing reads as not created yet.
    public static func readLogFolder(_ folder: URL) -> LogFolderState {
        let fm = FileManager.default
        let path = folder.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return .notCreatedYet }
        guard fm.isWritableFile(atPath: path) else { return .notWritable }
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(UInt64(0)) { sum, url in
            sum + UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return .ready(bytes: bytes)
    }
}

/// "Copy diagnostics report": the macOS and app version, the check results and the last run's counts,
/// for a GitHub issue. It never contains a path or a file name from the home folder: checks are
/// written from their state, and reasons have every path-like word removed.
public enum DiagnosticsReport {
    public struct Input: Sendable {
        public var macOS: String
        public var appVersion: String
        public var checks: [Diagnostics.Check]
        public var lastRun: RunRecord?
        public var home: URL
        public var generatedAt: Date

        public init(
            macOS: String, appVersion: String, checks: [Diagnostics.Check], lastRun: RunRecord?, home: URL,
            generatedAt: Date
        ) {
            self.macOS = macOS
            self.appVersion = appVersion
            self.checks = checks
            self.lastRun = lastRun
            self.home = home
            self.generatedAt = generatedAt
        }
    }

    public static func make(_ input: Input) -> String {
        var lines = ["Dustling diagnostics report"]
        lines.append("Created: \(input.generatedAt.ISO8601Format())")
        lines.append(scrub(input.macOS, home: input.home))
        lines.append("Dustling \(scrub(input.appVersion, home: input.home))")
        lines.append("")
        lines.append("Checks")
        for check in input.checks {
            lines.append("- \(check.title): \(check.chip). \(reportDetail(check))")
        }
        lines.append("")
        lines.append("Last run")
        if let run = input.lastRun {
            lines.append("- \(kindName(run.kind)), \(run.startedAt.ISO8601Format()), \(run.entries.count) items")
            let moved = run.entries.filter { if case .movedToTrash = $0.outcome { true } else { false } }.count
            lines.append("- \(moved) moved to the Trash, \(run.skippedCount) skipped, \(run.failedCount) failed, "
                         + "\(run.needsAdminCount) need admin rights")
            var reasons: [String: Int] = [:]
            var order: [String] = []
            for entry in run.entries {
                let reason: String
                switch entry.outcome {
                case .skipped(let r): reason = "skipped: " + (knownReason(r) ?? "other")
                case .failed(let r): reason = "failed: " + (knownReason(r) ?? "other error")
                case .needsAdmin: reason = "needs admin"
                case .movedToTrash, .deleted: continue
                }
                if reasons[reason] == nil { order.append(reason) }
                reasons[reason, default: 0] += 1
            }
            for reason in order { lines.append("- \(reason) (\(reasons[reason] ?? 0))") }
        } else {
            lines.append("- No runs yet")
        }
        lines.append("")
        lines.append("No file names from your home folder are included.")
        return lines.joined(separator: "\n")
    }

    /// The detail without any path: the log folder is reported by its state only.
    private static func reportDetail(_ check: Diagnostics.Check) -> String {
        switch check.kind {
        case .fullDiskAccess, .helper:
            return check.detail
        case .logFolder:
            switch check.state {
            case .warning: return "Dustling can't write to its log folder"
            default: return "Dustling can write its logs"
            }
        }
    }

    private static func kindName(_ kind: RunKind) -> String {
        switch kind {
        case .junkClean: return "Junk cleanup"
        case .uninstall: return "Uninstall"
        case .emptyTrash: return "Empty Trash"
        case .startupChange: return "Startup items change"
        }
    }

    /// Reasons the report may copy word for word: Dustling's own fixed reasons and the system's error
    /// strings. Free text (an error description that quotes a file name) never is.
    static let fixedReasons: Set<String> = {
        var set: Set<String> = [
            TrashMover.noAccessReason, "already gone", "excluded in Settings",
            "contains a folder excluded in Settings", "protected location", "another user's files",
            "outside the cleanup area", "cleanup stopped", CleanupSkip.reason,
            TrashMover.protectedReason,
            // The password step's own reasons.
            AdminScript.refusedReason, AdminScript.unsafeReason, AdminScript.putBackUnsafeReason,
            AdminScript.movedAwayReason, AdminScript.existsReason, AdminScript.noResultReason,
            AdminScript.skippedReason, OsascriptAdminShell.tooManyItemsReason, OsascriptAdminShell.stoppedReason,
            RunJournal.putBackNeedsPasswordReason,
        ]
        for code in Int32(1)...Int32(106) { set.insert(TrashMover.describe(code)) }
        return set
    }()

    /// The reason if it is in the fixed vocabulary (or "in use by <bundle id>"), else nil.
    static func knownReason(_ reason: String) -> String? {
        if fixedReasons.contains(reason) { return reason }
        if let id = LastRunReview.inUseBundleID(reason),
           id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) {
            return reason
        }
        return nil
    }

    /// Removes quoted runs, the home folder, the user name and every word that looks like a path.
    static func scrub(_ text: String, home: URL) -> String {
        let homePath = HistoryScreen.homeKey(home.path(percentEncoded: false))
        let user = home.lastPathComponent
        var out = text
        for (open, close) in [("\u{201C}", "\u{201D}"), ("\"", "\""), ("\u{2018}", "\u{2019}")] {
            while let start = out.range(of: open),
                  let end = out.range(of: close, range: start.upperBound..<out.endIndex) {
                out.replaceSubrange(start.lowerBound..<end.upperBound, with: "[name]")
            }
        }
        if !homePath.isEmpty { out = out.replacingOccurrences(of: homePath, with: "/[path]") }
        let words = out.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            if word.contains("/") || word.hasPrefix("~") { return "[path]" + (word.hasSuffix(":") ? ":" : "") }
            return String(word)
        }
        out = words.joined(separator: " ")
        if !user.isEmpty, user != "/" {
            out = out.replacingOccurrences(of: user, with: "[user]")
        }
        return out
    }
}
