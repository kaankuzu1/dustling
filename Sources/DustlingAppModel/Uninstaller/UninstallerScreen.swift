import DustlingCore
import Foundation

/// The Uninstaller screen's words and numbers (SCREENS-final §4): list captions, badges, leftover
/// notes, the detail totals and the action bar line. Pure, so the screen only lays them out.
public enum UninstallerScreen {
    public enum Sort: String, CaseIterable, Sendable {
        case size, name, lastUsed

        public var title: String {
            switch self {
            case .size: return "Size"
            case .name: return "Name"
            case .lastUsed: return "Last used"
            }
        }
    }

    public enum BadgeStyle: Equatable, Sendable { case neutral, warning, admin }

    // MARK: list

    /// The line under an app's name.
    public static func appCaption(_ row: AppRow) -> String {
        if row.label == "Steam game" { return "Steam game, no bundle ID" }
        if row.label == "Shortcut" { return "Shortcut, only the link is removed" }
        if row.isCounting { return "Looking for leftovers…" }
        switch row.leftoverCount {
        case 0: return "No leftovers"
        case 1: return "1 leftover"
        default: return "\(row.leftoverCount) leftovers"
        }
    }

    /// "Today", "Yesterday", "5 days ago", "2 weeks ago", "4 months ago". Nil when unknown.
    public static func lastUsed(_ date: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now))
            .day ?? 0
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s") ago" }
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case ..<14: return unit(days, "day")
        case ..<60: return unit(days / 7, "week")
        case ..<365: return unit(days / 30, "month")
        default: return unit(days / 365, "year")
        }
    }

    /// The list as shown: filtered by name (case and diacritics ignored), then sorted. Apps whose
    /// last use is unknown sort last under "Last used".
    public static func arrange(_ rows: [AppRow], query: String, sort: Sort) -> [AppRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = needle.isEmpty ? rows : rows.filter {
            $0.app.displayName.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        func byName(_ a: AppRow, _ b: AppRow) -> Bool {
            a.app.displayName.localizedStandardCompare(b.app.displayName) == .orderedAscending
        }
        switch sort {
        case .size:
            return shown.sorted { $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : byName($0, $1) }
        case .name:
            return shown.sorted(by: byName)
        case .lastUsed:
            return shown.sorted {
                switch ($0.app.lastUsed, $1.app.lastUsed) {
                case let (a?, b?): return a != b ? a > b : byName($0, $1)
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return byName($0, $1)
                }
            }
        }
    }

    // MARK: leftovers

    public static func badge(_ badge: LeftoverBadge) -> (text: String, style: BadgeStyle) {
        switch badge {
        case .teamID: return ("Team ID match", .neutral)
        case .helper: return ("Helper", .admin)
        case .nameMatch: return ("Name match", .neutral)
        case .yourData: return ("May contain your data", .warning)
        }
    }

    public static func kindName(_ kind: LeftoverKind) -> String {
        switch kind {
        case .applicationSupport: return "Application support"
        case .caches: return "Caches"
        case .preferences: return "Preferences"
        case .container: return "Container data"
        case .groupContainer: return "Group container"
        case .savedState: return "Saved window state"
        case .httpStorage: return "HTTP storage"
        case .webKit: return "WebKit data"
        case .logs: return "Logs"
        case .cookies: return "Cookies"
        case .launchAgent: return "Launch agent"
        case .launchDaemon: return "Launch daemon"
        case .privilegedHelper: return "Privileged helper"
        case .packageReceipt: return "Package receipt"
        case .steamGameData: return "Game data"
        }
    }

    public static let nameMatchNote = "Matched by name only, so it isn't checked"
    public static let helperNote = "Needs the cleanup helper (coming in a later version)"

    /// Why a row is disabled, unchecked or won't move now. The data warning is separate (`row.warning`).
    public static func note(for row: LeftoverRow) -> String? {
        if let reason = row.disabledReason { return sentence(reason) }
        if row.leftover.requiresAdmin { return helperNote }
        if row.leftover.match == .nameBased { return nameMatchNote }
        return nil
    }

    /// The detail header: what moves now (the app unless it is a link, plus checked leftovers that
    /// don't need the helper) and everything found.
    public static func totals(app: AppRow, leftovers: [LeftoverRow]) -> (selected: UInt64, found: UInt64) {
        let isLink = app.app.linkTarget != nil
        let moving = isLink ? 0 : leftovers
            .filter { $0.checked && !$0.isDisabled && !$0.leftover.requiresAdmin }
            .reduce(UInt64(0)) { $0 + $1.leftover.bytes }
        return ((isLink ? 0 : app.app.bytes) + moving, app.totalBytes)
    }

    // MARK: action bar

    public static func selectionLine(_ confirm: ConfirmModel) -> (title: String, caption: String) {
        guard !confirm.perApp.isEmpty else {
            return ("No apps selected", "Tick apps to remove them with their leftovers.")
        }
        let count = confirm.perApp.count
        let title = "\(count) \(count == 1 ? "app" : "apps") selected, \(Bytes.format(confirm.totalBytes))"
        if let note = confirm.note, !confirm.ready { return (title, note) }
        switch confirm.dataWarnings.count {
        case 0: return (title, "Apps and their leftovers move to the Trash together.")
        case 1:
            let warning = confirm.dataWarnings[0]
            return (title, "Includes \(warning.appName)'s \(kindName(warning.kind).lowercased()) you checked.")
        default: return (title, "Includes \(confirm.dataWarnings.count) data items you checked.")
        }
    }

    /// `~/Library/Caches/x`, without the trailing slash folder URLs carry.
    public static func path(_ url: URL, home: URL) -> String {
        var text = JunkScreen.displayPath(url, home: home)
        while text.count > 1 && text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// "excluded in Settings" -> "Excluded in Settings".
    public static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    static func names(_ list: [String]) -> String {
        switch list.count {
        case 0: return ""
        case 1: return list[0]
        case 2: return "\(list[0]) and \(list[1])"
        default: return list.dropLast().joined(separator: ", ") + " and " + list[list.count - 1]
        }
    }
}

/// The confirm sheet's text ("Move 3 apps to the Trash?").
public struct ConfirmText: Equatable, Sendable {
    public struct AppLine: Equatable, Sendable {
        public let name: String
        public let items: String
        public let bytes: String
    }

    public let title: String
    public let message: String
    public let apps: [AppLine]
    /// "1 item may contain your data:" when checked data items are included.
    public let dataHeading: String?
    public let dataLines: [String]
    /// Running apps quit first, agents unloaded, helper-only items left in place.
    public let notes: [String]
    /// Set when Dustling can't take things back out of the Trash (no Full Disk Access).
    public let limitedNote: String?
    public let total: String
    public let button: String

    public static func make(_ confirm: ConfirmModel) -> ConfirmText {
        let count = confirm.perApp.count
        let title = count == 1
            ? "Move \(confirm.perApp[0].name) to the Trash?" : "Move \(count) apps to the Trash?"
        let message = confirm.limitedNote == nil
            ? "Everything below goes to the Trash. You can put it back until you empty the Trash."
            : "Everything below goes to the Trash."
        let apps = confirm.perApp.map { app -> AppLine in
            let items = app.items + app.dataItems
            return AppLine(name: app.name, items: items == 1 ? "1 item" : "\(items) items", bytes: Bytes.format(app.bytes))
        }
        var heading: String?
        var lines: [String] = []
        let data = confirm.dataWarnings
        if !data.isEmpty {
            heading = data.count == 1 ? "1 item may contain your data:" : "\(data.count) items may contain your data:"
            lines = data.map {
                "\($0.appName) \(UninstallerScreen.kindName($0.kind).lowercased()), \(Bytes.format($0.bytes))."
            }
            let why = data.count == 1 ? "It is included because you checked it." : "They are included because you checked them."
            lines[lines.count - 1] += " " + why
        }
        var notes: [String] = []
        let running = confirm.runningApps
        if running.count == 1 {
            notes.append("\(running[0]) is running. Dustling will quit it first.")
        } else if running.count > 1 {
            notes.append("\(UninstallerScreen.names(running)) are running. Dustling will quit them first.")
        }
        if confirm.launchAgents == 1 {
            notes.append("1 launch agent is unloaded before it moves.")
        } else if confirm.launchAgents > 1 {
            notes.append("\(confirm.launchAgents) launch agents are unloaded before they move.")
        }
        if confirm.accessSkipped == 1 {
            notes.append("1 item needs Full Disk Access and stays where it is.")
        } else if confirm.accessSkipped > 1 {
            notes.append("\(confirm.accessSkipped) items need Full Disk Access and stay where they are.")
        }
        if confirm.adminItems == 1 {
            notes.append("1 item needs the cleanup helper (coming in a later version) and stays where it is.")
        } else if confirm.adminItems > 1 {
            notes.append("\(confirm.adminItems) items need the cleanup helper (coming in a later version) "
                + "and stay where they are.")
        }
        let button: String
        switch running.count {
        case 0: button = "Move to Trash"
        case 1: button = "Quit \(running[0]) and move to Trash"
        default: button = "Quit \(running.count) apps and move to Trash"
        }
        return ConfirmText(
            title: title, message: message, apps: apps, dataHeading: heading, dataLines: lines, notes: notes,
            limitedNote: confirm.limitedNote, total: Bytes.format(confirm.totalBytes), button: button)
    }
}

/// The Removing state: app by app, each item waiting, moving, then finished with its outcome.
public struct UninstallProgress: Equatable, Sendable {
    public enum ItemState: Equatable, Sendable {
        case waiting, moving
        case finished(DeletionOutcome)
    }

    public enum AppState: Equatable, Sendable {
        case waiting, quitting, removing
        case finished(removed: Bool)
        /// Stop was pressed before this app's turn; nothing of it was touched.
        case stopped
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let url: URL
        /// "Application" or the leftover's kind.
        public let title: String
        public let requiresAdmin: Bool
        public var bytes: UInt64
        public var state: ItemState
        public var id: URL { url }
    }

    public struct AppEntry: Identifiable, Equatable, Sendable {
        public let app: InstalledApp
        public var items: [Item]
        public var state: AppState
        public var id: URL { app.url }
        public var doneCount: Int { items.filter { if case .finished = $0.state { true } else { false } }.count }
    }

    public private(set) var apps: [AppEntry]

    public init(plan: [ConfirmModel.Planned]) {
        apps = plan.map { planned in
            let appItem = Item(url: planned.app.url, title: "Application", requiresAdmin: false,
                               bytes: planned.app.linkTarget == nil ? planned.app.bytes : 0, state: .waiting)
            // The uninstaller moves the app, then the user's leftovers; helper-only items come last.
            let ordered = planned.leftovers.filter { !$0.requiresAdmin } + planned.leftovers.filter(\.requiresAdmin)
            return AppEntry(app: planned.app, items: [appItem] + ordered.map {
                Item(url: $0.url, title: UninstallerScreen.kindName($0.kind), requiresAdmin: $0.requiresAdmin,
                     bytes: $0.bytes, state: .waiting)
            }, state: .waiting)
        }
    }

    /// The app being quit or removed now.
    public var current: AppEntry? {
        apps.first { $0.state == .quitting || $0.state == .removing }
    }

    public var appsDone: Int {
        apps.filter { if case .finished = $0.state { true } else { false } }.count
    }

    /// What has reached the Trash so far.
    public var bytesMoved: UInt64 {
        apps.reduce(0) { total, app in
            total + app.items.reduce(0) { sum, item in
                if case .finished(.movedToTrash) = item.state { return sum + item.bytes }
                return sum
            }
        }
    }

    public mutating func quitting(_ id: URL) {
        update(id) { $0.state = .quitting }
    }

    public mutating func begin(_ id: URL) {
        update(id) { entry in
            entry.state = .removing
            Self.advance(&entry)
        }
    }

    /// One item finished (the uninstaller's per-item callback). Ignored once the app has finished.
    public mutating func record(_ url: URL, _ outcome: DeletionOutcome, in id: URL) {
        update(id) { entry in
            guard entry.state == .removing,
                  let index = entry.items.firstIndex(where: { $0.url == url && !Self.isFinished($0) }) else { return }
            entry.items[index].state = .finished(outcome)
            Self.advance(&entry)
        }
    }

    /// The app's record is the final word on every item, including helper-only ones.
    public mutating func finish(_ id: URL, record: RunRecord) {
        update(id) { entry in
            for index in entry.items.indices {
                let path = entry.items[index].url.path(percentEncoded: false)
                if let journal = record.entries.first(where: { $0.originalPath == path }) {
                    entry.items[index].state = .finished(journal.outcome)
                    entry.items[index].bytes = journal.bytes
                } else if !Self.isFinished(entry.items[index]) {
                    entry.items[index].state = .waiting
                }
            }
            let removed: Bool
            if case .movedToTrash = record.entries.first?.outcome { removed = true } else { removed = false }
            entry.state = .finished(removed: removed)
        }
    }

    /// Stop: apps that haven't started are left alone.
    public mutating func stopRemaining() {
        for index in apps.indices where apps[index].state == .waiting {
            apps[index].state = .stopped
        }
    }

    private mutating func update(_ id: URL, _ change: (inout AppEntry) -> Void) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        change(&apps[index])
    }

    private static func isFinished(_ item: Item) -> Bool {
        if case .finished = item.state { return true }
        return false
    }

    /// The next item the uninstaller works on shows a spinner.
    private static func advance(_ entry: inout AppEntry) {
        guard !entry.items.contains(where: { $0.state == .moving }),
              let next = entry.items.firstIndex(where: { $0.state == .waiting && !$0.requiresAdmin }) else { return }
        entry.items[next].state = .moving
    }
}

/// The finished uninstall, from the records only (never fail silently).
public struct UninstallSummary: Equatable, Sendable {
    public struct Problem: Equatable, Sendable {
        public let path: String
        public let reason: String
    }

    public struct AppLine: Identifiable, Equatable, Sendable {
        public let record: RunRecord
        public let name: String
        public let removed: Bool
        public let movedBytes: UInt64
        /// "2 items moved, 1 failed" or "Left alone: still running".
        public let status: String
        public let problems: [Problem]
        /// Something of it is in the Trash and the record allows putting it back.
        public let canPutBack: Bool
        public var id: UUID { record.id }
    }

    public let movedBytes: UInt64
    public let sentence: String
    public let apps: [AppLine]

    public static func make(records: [RunRecord], stopped: [String], home: URL) -> UninstallSummary {
        var lines: [AppLine] = []
        var removedCount = 0
        var leftAlone: [String] = []
        for record in records {
            let name: String
            if case .uninstall(let appName) = record.kind { name = appName } else { name = "App" }
            guard let first = record.entries.first else { continue }
            let removed: Bool
            if case .movedToTrash = first.outcome { removed = true } else { removed = false }
            let moved = record.entries.filter { if case .movedToTrash = $0.outcome { true } else { false } }
            let bytes = moved.reduce(UInt64(0)) { $0 + $1.bytes }
            if removed {
                removedCount += 1
                let failed = record.entries.filter { if case .failed = $0.outcome { true } else { false } }.count
                let skipped = record.entries.filter { if case .skipped = $0.outcome { true } else { false } }.count
                let admin = record.entries.filter { $0.outcome == .needsAdmin }.count
                var status = moved.count == 1 ? "1 item moved" : "\(moved.count) items moved"
                if skipped > 0 { status += ", \(skipped) skipped" }
                if failed > 0 { status += ", \(failed) failed" }
                if admin == 1 { status += ", 1 needs the cleanup helper" }
                if admin > 1 { status += ", \(admin) need the cleanup helper" }
                let problems = record.entries.compactMap { entry -> Problem? in
                    if case .movedToTrash = entry.outcome { return nil }
                    let path = entry.originalPath.hasPrefix("/")
                        ? UninstallerScreen.path(URL(filePath: entry.originalPath), home: home) : entry.originalPath
                    let reason = entry.outcome == .needsAdmin ? "needs the cleanup helper" : entry.outcome.label
                    return Problem(path: path, reason: reason)
                }
                lines.append(AppLine(
                    record: record, name: name, removed: true, movedBytes: bytes, status: status, problems: problems,
                    canPutBack: record.restorable && !moved.isEmpty))
            } else {
                let reason = Self.reason(first.outcome)
                leftAlone.append("\(name) was left alone: \(reason).")
                lines.append(AppLine(
                    record: record, name: name, removed: false, movedBytes: bytes, status: "Left alone: \(reason)",
                    problems: [], canPutBack: false))
            }
        }
        var parts: [String] = []
        switch removedCount {
        case 0: parts.append("No apps were moved to the Trash.")
        case 1: parts.append("1 app moved to the Trash.")
        default: parts.append("\(removedCount) apps moved to the Trash.")
        }
        parts += leftAlone
        if !stopped.isEmpty {
            parts.append("Stopped before \(UninstallerScreen.names(stopped)), so "
                + (stopped.count == 1 ? "it was" : "they were") + " left alone.")
        }
        return UninstallSummary(
            movedBytes: lines.reduce(0) { $0 + $1.movedBytes }, sentence: parts.joined(separator: " "), apps: lines)
    }

    private static func reason(_ outcome: DeletionOutcome) -> String {
        switch outcome {
        case .skipped(let reason), .failed(let reason): return reason
        case .needsAdmin: return "needs the cleanup helper"
        case .movedToTrash, .deleted: return outcome.label
        }
    }
}
