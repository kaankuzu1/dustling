import DustlingCore
import Foundation

/// The History screen's wording and rules (SCREENS-final §6), kept free of SwiftUI so they can be
/// tested: run rows, the timeline with its dashed Empty Trash line, item statuses, the readable log,
/// its filters, the bug-report text and what a restore did. Every outcome is shown as it happened.
public enum HistoryScreen {
    /// What the screen needs besides the runs. `canTakeOutOfTrash` is false without Full Disk Access.
    public struct Context: Sendable {
        public var lastEmptyTrash: Date?
        public var canTakeOutOfTrash: Bool
        /// The home folder's path, shown as `~`.
        public var home: String
        public var now: Date
        public var calendar: Calendar
        public var locale: Locale

        public init(
            lastEmptyTrash: Date?, canTakeOutOfTrash: Bool, home: String, now: Date = .now,
            calendar: Calendar = .current, locale: Locale = .current
        ) {
            self.lastEmptyTrash = lastEmptyTrash
            self.canTakeOutOfTrash = canTakeOutOfTrash
            self.home = home
            self.now = now
            self.calendar = calendar
            self.locale = locale
        }

        func isBeforeLastEmpty(_ date: Date) -> Bool {
            lastEmptyTrash.map { date < $0 } ?? false
        }
    }

    // MARK: dates

    private static func format(_ template: String, _ date: Date, _ c: Context) -> String {
        let f = DateFormatter()
        f.locale = c.locale
        f.calendar = c.calendar
        f.timeZone = c.calendar.timeZone
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: c.locale)
        return f.string(from: date)
    }

    private static func time(_ date: Date, _ c: Context) -> String { format("jmm", date, c) }

    private static func day(_ date: Date, _ c: Context) -> String {
        let sameYear = c.calendar.component(.year, from: date) == c.calendar.component(.year, from: c.now)
        return format(sameYear ? "dMMM" : "dMMMyyyy", date, c)
    }

    /// "Today, 19:04", "Yesterday, 21:12", "4 Nov, 10:22", "28 Oct 2025, 16:05".
    public static func when(_ date: Date, _ c: Context) -> String {
        if c.calendar.isDate(date, inSameDayAs: c.now) { return "Today, \(time(date, c))" }
        if let yesterday = c.calendar.date(byAdding: .day, value: -1, to: c.now),
           c.calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time(date, c))"
        }
        return "\(day(date, c)), \(time(date, c))"
    }

    // MARK: runs

    public enum Tool: Equatable, Sendable {
        case junkScan, uninstaller, startupItems, emptyTrash

        public var title: String {
            switch self {
            case .junkScan: "Junk scan"
            case .uninstaller: "Uninstaller"
            case .startupItems: "Startup items"
            case .emptyTrash: "Empty Trash"
            }
        }

        static func of(_ kind: RunKind) -> Tool {
            switch kind {
            case .junkClean: .junkScan
            case .uninstall: .uninstaller
            case .startupChange: .startupItems
            case .emptyTrash: .emptyTrash
            }
        }
    }

    public enum Chip: Equatable, Sendable {
        case canBeRestored, trashEmptied, putBack, notInTrash, movedToTrash, turnedOff, turnedOn, failed
        /// The run is still marked in progress while Dustling is working on it.
        case stillRunning
        /// The run is marked in progress but nothing is working on it: it never finished.
        case interrupted

        public var text: String {
            switch self {
            case .stillRunning: "Still running"
            case .interrupted: "Interrupted"
            case .canBeRestored: "Can be restored"
            case .trashEmptied: "Trash emptied"
            case .putBack: "Put back"
            case .notInTrash: "No longer in the Trash"
            case .movedToTrash: "Moved to Trash"
            case .turnedOff: "Turned off"
            case .turnedOn: "Turned on"
            case .failed: "Failed"
            }
        }

        public var tone: Tone {
            switch self {
            case .canBeRestored, .putBack: .success
            case .failed, .interrupted: .warning
            default: .neutral
            }
        }
    }

    public enum Tone: Equatable, Sendable { case neutral, success, warning }

    public enum RunAction: Equatable, Sendable {
        case restore
        /// Without Full Disk Access Dustling can't take things out of the Trash; Finder can.
        case showInTrash
    }

    public struct RunLine: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let tool: Tool
        /// "Uninstaller: Docker Desktop".
        public let title: String
        /// "Today, 19:04" for the timeline's header.
        public let when: String
        /// "Today, 19:04, 40 items, 2 skipped".
        public let caption: String
        public let chip: Chip?
        public let size: String?
        public let action: RunAction?
        /// Runs whose files are gone for good read quieter.
        public let dimmed: Bool
    }

    private static func isMove(_ entry: JournalEntry) -> Bool {
        if case .movedToTrash = entry.outcome { true } else { false }
    }

    /// The startup item a startup run touched, from its plist's file name.
    private static func startupName(_ record: RunRecord) -> String? {
        guard let path = record.entries.first(where: { !$0.originalPath.hasPrefix("<") })?.originalPath else { return nil }
        let name = URL(filePath: path).lastPathComponent
        return name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
    }

    public static func runTitle(_ record: RunRecord) -> String {
        let tool = Tool.of(record.kind)
        switch record.kind {
        case .uninstall(let name): return "\(tool.title): \(name)"
        case .startupChange: return startupName(record).map { "\(tool.title): \($0)" } ?? tool.title
        case .junkClean, .emptyTrash: return tool.title
        }
    }

    public static func runLine(_ row: RunRow, _ c: Context) -> RunLine {
        let record = row.record
        let real = record.entries.filter { !$0.originalPath.hasPrefix("<") }
        let toggles = record.entries.filter { OutcomePresentation.isSuccessfulToggle($0.outcome, in: record.kind) }
        let moved = real.filter(isMove)
        let failed = record.failedCount
        let helper = record.needsAdminCount
        let skipped = record.skippedCount - toggles.count

        // The timeline's header already says when.
        var parts: [String] = []
        if let toggle = toggles.first, real.count == 1 {
            parts.append(OutcomePresentation.text(toggle.outcome, in: record.kind).lowercased())
        } else {
            parts.append("\(real.count.formatted(.number.locale(Locale(identifier: "en_US")))) \(real.count == 1 ? "item" : "items")")
        }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        if helper > 0 { parts.append("\(helper) \(helper == 1 ? "needs" : "need") the helper") }

        var chip: Chip?
        var action: RunAction?
        var dimmed = false
        if row.inProgress {
            // Never offered for Put back until it is finished (recovered at the next launch).
            chip = row.chip == "Still running" ? .stillRunning : .interrupted
        } else if record.kind == .emptyTrash {
            chip = nil
        } else if !moved.isEmpty {
            if c.isBeforeLastEmpty(record.startedAt) {
                chip = .trashEmptied
                dimmed = true
            } else if moved.allSatisfy(\.restored) {
                chip = .putBack
            } else if row.restorable {
                chip = .canBeRestored
                action = c.canTakeOutOfTrash ? .restore : .showInTrash
            } else if !c.canTakeOutOfTrash {
                // Without Full Disk Access the Trash can't be checked: say only what is known.
                chip = .movedToTrash
                action = .showInTrash
            } else {
                chip = .notInTrash
            }
        } else if let toggle = toggles.first, failed == 0 {
            chip = toggle.outcome == .skipped(reason: "disabled") ? .turnedOff : .turnedOn
        } else if failed > 0 && moved.isEmpty && record.kind == .startupChange {
            chip = .failed
        }

        let bytes: UInt64 = record.kind == .emptyTrash
            ? record.entries.reduce(0) { $1.outcome == .deleted ? $0 + $1.bytes : $0 }
            : record.bytesMovedToTrash
        let showsSize = record.kind == .emptyTrash ? bytes > 0 : !moved.isEmpty
        return RunLine(
            id: record.id, tool: Tool.of(record.kind), title: runTitle(record), when: when(record.startedAt, c),
            caption: sentence(parts.joined(separator: ", ")), chip: chip, size: showsSize ? Bytes.format(bytes) : nil,
            action: action, dimmed: dimmed)
    }

    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    public enum TimelineEntry: Identifiable, Equatable, Sendable {
        case run(RunLine)
        /// The dashed line under the last Empty Trash.
        case trashEmptied(String)

        public enum Kind: Equatable, Sendable { case run, cut }

        public var kind: Kind {
            if case .run = self { .run } else { .cut }
        }

        public var cutText: String? {
            if case .trashEmptied(let text) = self { text } else { nil }
        }

        public var id: String {
            switch self {
            case .run(let line): line.id.uuidString
            case .trashEmptied: "trash-emptied"
            }
        }
    }

    /// Newest first, with the dashed line right below the last Empty Trash run.
    public static func timeline(_ rows: [RunRow], _ c: Context) -> [TimelineEntry] {
        let sorted = rows.sorted { $0.record.startedAt > $1.record.startedAt }
        let lastEmpty = c.lastEmptyTrash == nil ? nil : sorted.first { $0.record.kind == .emptyTrash }
        var entries: [TimelineEntry] = []
        for row in sorted {
            entries.append(.run(runLine(row, c)))
            if let lastEmpty, row.id == lastEmpty.id {
                entries.append(.trashEmptied(cutText(lastEmpty.record.startedAt, c)))
            }
        }
        return entries
    }

    private static func cutText(_ date: Date, _ c: Context) -> String {
        let on: String
        if c.calendar.isDate(date, inSameDayAs: c.now) {
            on = "today"
        } else if let yesterday = c.calendar.date(byAdding: .day, value: -1, to: c.now),
                  c.calendar.isDate(date, inSameDayAs: yesterday) {
            on = "yesterday"
        } else {
            on = "on \(day(date, c))"
        }
        return "Trash emptied \(on). Older runs can't be restored."
    }

    /// "5 runs, 3 can still be restored".
    public static func subtitle(_ rows: [RunRow], isLoading: Bool) -> String {
        if rows.isEmpty { return isLoading ? "Reading History…" : "No runs yet" }
        let restorable = rows.filter(\.restorable).count
        let runs = "\(rows.count) \(rows.count == 1 ? "run" : "runs")"
        return restorable == 0 ? "\(runs), none can be restored" : "\(runs), \(restorable) can still be restored"
    }

    // MARK: items

    /// The All items table's Run column: "Uninstaller, today", "Junk scan, 4 Nov".
    public static func runColumn(_ kind: RunKind, _ date: Date, _ c: Context) -> String {
        let on: String
        if c.calendar.isDate(date, inSameDayAs: c.now) {
            on = "today"
        } else if let yesterday = c.calendar.date(byAdding: .day, value: -1, to: c.now),
                  c.calendar.isDate(date, inSameDayAs: yesterday) {
            on = "yesterday"
        } else {
            on = day(date, c)
        }
        return "\(Tool.of(kind).title), \(on)"
    }

    public struct ItemStatus: Equatable, Sendable {
        public let text: String
        public let tone: Tone
    }

    /// Where one item is now, for the All items table.
    public static func itemStatus(
        _ entry: JournalEntry, kind: RunKind, runDate: Date, restorable: Bool, _ c: Context
    ) -> ItemStatus {
        if case .movedToTrash = entry.outcome {
            if entry.restored { return ItemStatus(text: "Put back", tone: .success) }
            if entry.gone { return ItemStatus(text: "No longer in the Trash", tone: .neutral) }
            if c.isBeforeLastEmpty(runDate) { return ItemStatus(text: "Trash emptied", tone: .neutral) }
            if restorable { return ItemStatus(text: "In the Trash", tone: .neutral) }
            if !c.canTakeOutOfTrash { return ItemStatus(text: "Moved to Trash", tone: .neutral) }
            return ItemStatus(text: "No longer in the Trash", tone: .neutral)
        }
        let text = OutcomePresentation.text(entry.outcome, in: kind)
        switch entry.outcome {
        case .skipped where OutcomePresentation.isSuccessfulToggle(entry.outcome, in: kind):
            return ItemStatus(text: text, tone: .neutral)
        case .skipped, .failed, .needsAdmin: return ItemStatus(text: text, tone: .warning)
        case .deleted, .movedToTrash: return ItemStatus(text: text, tone: .neutral)
        }
    }

    /// A path for the screen: the home folder as `~`, and the journal's own markers in words.
    public static func displayPath(_ path: String, home: String) -> String {
        switch path {
        case "<history>": return "Dustling's history file"
        case "<log>": return "Dustling's log file"
        default: return shortened(path, home: home)
        }
    }

    /// The home folder's path without trailing slashes: a directory URL's path ends in "/"
    /// (`/Users/k/`), which would never match `home + "/"`.
    public static func homeKey(_ home: String) -> String {
        var home = home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        return home == "/" ? "" : home
    }

    static func shortened(_ path: String, home: String) -> String {
        let home = homeKey(home)
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: log

    public enum LogFilter: Hashable, CaseIterable, Sendable {
        case all, moved, skipped, failed

        public func includes(_ row: LogRow) -> Bool {
            switch self {
            case .all: true
            case .moved: row.tone == .done
            case .skipped: row.tone == .skipped
            case .failed: row.tone == .failed
            }
        }
    }

    public struct LogRow: Identifiable, Equatable, Sendable {
        public enum Tone: Equatable, Sendable { case done, skipped, failed }
        public let id: Int
        /// "moved", "skipped", "failed", "needs helper", "deleted", "turned off", "put back".
        public let result: String
        public let tone: Tone
        public let path: String
        /// The size, or the reason.
        public let note: String
    }

    public static func logRows(_ record: RunRecord, _ c: Context) -> [LogRow] {
        record.entries.enumerated().map { index, entry in
            let path = displayPath(entry.originalPath, home: c.home)
            let size = Bytes.format(entry.bytes)
            switch entry.outcome {
            case .movedToTrash:
                return LogRow(id: index, result: entry.restored ? "put back" : "moved", tone: .done, path: path, note: size)
            case .deleted:
                return LogRow(id: index, result: "deleted", tone: .done, path: path, note: size)
            case .skipped(let reason):
                if OutcomePresentation.isSuccessfulToggle(entry.outcome, in: record.kind) {
                    let text = OutcomePresentation.text(entry.outcome, in: record.kind).lowercased()
                    return LogRow(id: index, result: text, tone: .done, path: path, note: "")
                }
                return LogRow(id: index, result: "skipped", tone: .skipped, path: path, note: reason)
            case .needsAdmin:
                return LogRow(id: index, result: "needs helper", tone: .skipped, path: path, note: "needs the cleanup helper")
            case .failed(let reason):
                return LogRow(id: index, result: "failed", tone: .failed, path: path, note: reason)
            }
        }
    }

    public struct LogFilterChip: Hashable, Sendable {
        public let filter: LogFilter
        public let label: String
    }

    /// "All 30,367", "Moved 30,365", "Skipped 2", "Failed 0". The done chip reads "Deleted" for an
    /// Empty Trash run and "Changed" for a startup change.
    public static func logFilters(_ record: RunRecord, _ c: Context) -> [LogFilterChip] {
        let rows = logRows(record, c)
        let done: String
        switch record.kind {
        case .emptyTrash: done = "Deleted"
        case .startupChange: done = "Changed"
        case .junkClean, .uninstall: done = "Moved"
        }
        func count(_ filter: LogFilter) -> String {
            rows.filter { filter.includes($0) }.count.formatted(.number.locale(Locale(identifier: "en_US")))
        }
        return [
            LogFilterChip(filter: .all, label: "All \(count(.all))"),
            LogFilterChip(filter: .moved, label: "\(done) \(count(.moved))"),
            LogFilterChip(filter: .skipped, label: "Skipped \(count(.skipped))"),
            LogFilterChip(filter: .failed, label: "Failed \(count(.failed))"),
        ]
    }

    /// "Junk scan, today 19:04".
    public static func logTitle(_ record: RunRecord, _ c: Context) -> String {
        let at: String
        if c.calendar.isDate(record.startedAt, inSameDayAs: c.now) {
            at = "today \(time(record.startedAt, c))"
        } else if let yesterday = c.calendar.date(byAdding: .day, value: -1, to: c.now),
                  c.calendar.isDate(record.startedAt, inSameDayAs: yesterday) {
            at = "yesterday \(time(record.startedAt, c))"
        } else {
            at = "\(day(record.startedAt, c)) \(time(record.startedAt, c))"
        }
        return "\(runTitle(record)), \(at)"
    }

    // MARK: bug report

    /// The run's own lines from the log file (its header, its items, its totals), with the home
    /// folder shown as `~`. When the log doesn't have them (it couldn't be written or was deleted),
    /// the same lines are made from the saved record.
    public static func bugReport(logText: String?, record: RunRecord, home: String) -> String {
        let fallback = RunLogger.text(for: record)
        let text = logText.flatMap { ownLines(in: $0, record: record, expectedTotals: fallback) } ?? fallback
        return shortenedEverywhere(text, home: home)
    }

    /// The run's header, then one line per entry in order (each must end with that entry's path, and
    /// the Trash path for a move), then its totals line. Lines of other runs written in between
    /// (the log is shared) are skipped. Nil when the log doesn't hold exactly this run's lines.
    private static func ownLines(in log: String, record: RunRecord, expectedTotals: String) -> String? {
        let marker = "run=\(record.id.uuidString)"
        let totals = expectedTotals.split(separator: "\n").last.map(String.init)
        var lines: [Substring] = []
        var next = 0
        var started = false
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if !started {
                if !line.hasPrefix("  ") && line.contains(marker) {
                    started = true
                    lines.append(line)
                }
                continue
            }
            if next < record.entries.count {
                let entry = record.entries[next]
                var suffix = "  " + entry.originalPath
                if case .movedToTrash(let trashed) = entry.outcome { suffix += " -> " + trashed }
                if line.hasPrefix("  ") && !line.hasPrefix("  total:") && line.hasSuffix(suffix)
                    && line.hasPrefix("  " + entry.outcome.label + "  ") {
                    lines.append(line)
                    next += 1
                }
            } else if line.hasPrefix("  total:") && String(line) == totals {
                lines.append(line)
                return lines.joined(separator: "\n") + "\n"
            }
        }
        return nil
    }

    private static func shortenedEverywhere(_ text: String, home: String) -> String {
        let home = homeKey(home)
        guard !home.isEmpty else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: home)
        guard let regex = try? NSRegularExpression(pattern: escaped + "(?=/|\\s|$)") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "~")
    }

    // MARK: restore

    public struct RestoreSummary: Equatable, Sendable {
        public let success: Bool
        public let title: String
        /// One line per item that didn't come back: its name and why.
        public let problems: [String]
    }

    public static func restoreSummary(_ outcomes: [RestoreOutcome]) -> RestoreSummary {
        var back = 0
        var problems: [String] = []
        func name(_ path: String) -> String { URL(filePath: path).lastPathComponent }
        for outcome in outcomes {
            switch outcome {
            case .restored: back += 1
            case .conflict(let path): problems.append("\(name(path)): something with the same name is already there")
            case .missingFromTrash(let path): problems.append("\(name(path)): no longer in the Trash")
            case .failed(let path, let reason): problems.append("\(name(path)): \(reason)")
            }
        }
        let items = "\(back) \(back == 1 ? "item" : "items")"
        let title: String
        if problems.isEmpty {
            title = "Put back \(items)."
        } else if back == 0 {
            title = "Nothing was put back."
        } else {
            title = "Put back \(items). \(problems.count) didn't come back."
        }
        return RestoreSummary(success: problems.isEmpty && back > 0, title: title, problems: problems)
    }
}
