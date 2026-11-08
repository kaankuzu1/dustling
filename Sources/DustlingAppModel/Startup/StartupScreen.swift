import DustlingCore
import Foundation

/// The Startup items screen's wording and rules (SCREENS-final §5), kept free of SwiftUI so they can
/// be tested: names, owners, group headers, the toolbar filter, badges, the orphan banner and what a
/// change did.
public enum StartupScreen {
    static let helperNote = "Needs the cleanup helper (coming in a later version)"

    // MARK: names and owners

    /// The app an item belongs to: what the scanner found, else the installed app whose bundle holds
    /// the program, else the app bundle in the program's path when it is on disk.
    public struct Owner: Equatable, Sendable {
        public let name: String
        public let appURL: URL?
    }

    /// What people would call the item: the innermost app bundle its program runs from, else the
    /// program's file name, else the label. System tools (`/usr/bin/open`) say nothing about the item.
    public static func displayName(_ item: StartupItem) -> String {
        guard let program = item.program, program.hasPrefix("/") else { return item.label }
        let parts = URL(filePath: program).standardizedFileURL.pathComponents
        if let app = parts.last(where: { $0.lowercased().hasSuffix(".app") }) { return String(app.dropLast(4)) }
        let systemFolders = ["/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/libexec", "/System"]
        if systemFolders.contains(where: { program == $0 || program.hasPrefix($0 + "/") }) { return item.label }
        return parts.last ?? item.label
    }

    public static func owner(
        of item: StartupItem, apps: [InstalledApp], isPresent: (String) -> Bool = { ProgramPresence.check($0) == .present }
    ) -> Owner? {
        if let known = item.ownerAppName { return Owner(name: known, appURL: nil) }
        guard let program = item.program, program.hasPrefix("/") else { return nil }
        let parts = URL(filePath: program).standardizedFileURL.pathComponents
        for app in apps {
            let appParts = app.url.standardizedFileURL.pathComponents
            if parts.count > appParts.count, Array(parts.prefix(appParts.count)) == appParts {
                return Owner(name: app.displayName, appURL: app.url)
            }
        }
        guard let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        let bundle = NSString.path(withComponents: Array(parts.prefix(index + 1)))
        guard isPresent(bundle) else { return nil }
        return Owner(name: String(parts[index].dropLast(4)), appURL: URL(filePath: bundle, directoryHint: .isDirectory))
    }

    /// The app an orphaned item came with, from the outermost app bundle in its program's path.
    public static func removedAppName(program: String?) -> String? {
        guard let program, program.hasPrefix("/") else { return nil }
        let parts = URL(filePath: program).standardizedFileURL.pathComponents
        return parts.first { $0.lowercased().hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    public static func kindName(_ scope: StartupScope) -> String {
        switch scope {
        case .loginItem: "Login item"
        case .userAgent, .systemAgent: "Launch agent"
        case .systemDaemon: "Launch daemon"
        }
    }

    // MARK: groups and the toolbar filter

    public static func heading(_ kind: StartupGroupKind) -> String {
        switch kind {
        case .loginItems: "Login items"
        case .agents: "Launch agents"
        case .daemons: "Launch daemons"
        }
    }

    public static func caption(_ kind: StartupGroupKind) -> String {
        switch kind {
        case .loginItems: "Open when you log in"
        case .agents: "Run in the background for your account"
        case .daemons: "System services, changed through the helper"
        }
    }

    public static func onCount(on: Int, total: Int) -> String { "\(on) of \(total) on" }

    /// "10 items, 9 turned on".
    public static func subtitle(_ items: [StartupItem], isLoading: Bool) -> String {
        if items.isEmpty { return isLoading ? "Looking for startup items…" : "No startup items found" }
        let on = items.filter(\.isEnabled).count
        return "\(items.count) \(items.count == 1 ? "item" : "items"), \(on) turned on"
    }

    public enum Filter: Hashable, CaseIterable, Sendable {
        case all, loginItems, agents, daemons

        public func shows(_ kind: StartupGroupKind) -> Bool {
            switch self {
            case .all: true
            case .loginItems: kind == .loginItems
            case .agents: kind == .agents
            case .daemons: kind == .daemons
            }
        }
    }

    public struct Segment: Hashable, Sendable {
        public let filter: Filter
        public let label: String
    }

    /// "All 10", "Login items", "Agents 4", "Daemons 2". Login items can't be listed (macOS has no
    /// API for other apps' login items), so that segment has no count rather than a false 0.
    public static func segments(_ items: [StartupItem]) -> [Segment] {
        func count(_ kind: StartupGroupKind) -> Int { items.filter { StartupGroupKind.of($0.scope) == kind }.count }
        return [
            Segment(filter: .all, label: "All \(items.count)"),
            Segment(filter: .loginItems, label: "Login items"),
            Segment(filter: .agents, label: "Agents \(count(.agents))"),
            Segment(filter: .daemons, label: "Daemons \(count(.daemons))"),
        ]
    }

    // MARK: badges

    public enum Badge: Equatable, Sendable {
        case appNotFound, inSystemSettings, helper

        public var text: String {
            switch self {
            case .appNotFound: "App not found"
            case .inSystemSettings: "In System Settings"
            case .helper: "Helper"
            }
        }

        public var help: String {
            switch self {
            case .appNotFound: "The app this item came with isn't on this Mac any more"
            case .inSystemSettings: "macOS only lets System Settings change this item"
            case .helper: StartupScreen.helperNote
            }
        }
    }

    public static func badge(scope: StartupScope, orphaned: Bool, systemSettingsOnly: Bool) -> Badge? {
        if orphaned { return .appNotFound }
        if systemSettingsOnly || scope == .loginItem { return .inSystemSettings }
        if scope == .systemAgent || scope == .systemDaemon { return .helper }
        return nil
    }

    // MARK: orphan banner

    public struct OrphanBannerText: Equatable, Sendable {
        public let title: String
        public let message: String
        /// At least one orphan is on and can be turned off.
        public let showsTurnOff: Bool
        /// At least one orphan can be removed.
        public let showsRemove: Bool
    }

    /// The banner at the top for items whose program is gone. `canChange` says whether Dustling can
    /// turn off or remove an item itself (user launch agents); the others need the helper.
    public static func orphanBanner(_ orphans: [StartupItem], canChange: (StartupItem) -> Bool) -> OrphanBannerText? {
        guard let first = orphans.first else { return nil }
        let changeable = orphans.filter(canChange)
        let title: String
        var message: String
        if orphans.count == 1 {
            if let app = removedAppName(program: first.program) {
                title = first.isEnabled
                    ? "\(app) was uninstalled, but its startup item still runs."
                    : "\(app) was uninstalled, but its startup item is still here."
                message = "It can't do anything useful without the app."
            } else {
                let name = displayName(first)
                title = first.isEnabled
                    ? "The program behind \(name) is gone, but the item still runs."
                    : "The program behind \(name) is gone, but the item is still here."
                message = "It can't do anything useful without its program."
            }
            if !changeable.isEmpty {
                message += first.isEnabled
                    ? " Turning it off is reversible, and removing it moves it to the Trash."
                    : " Removing it moves it to the Trash."
            }
        } else {
            title = "\(orphans.count) startup items belong to apps that were uninstalled."
            message = "They can't do anything useful without their apps."
            if !changeable.isEmpty {
                message += " Turning them off is reversible, and removing them moves them to the Trash."
            }
        }
        if changeable.count < orphans.count {
            message += changeable.isEmpty
                ? " \(helperNote)."
                : " Some of them can't be changed yet: \(helperNote.prefix(1).lowercased() + helperNote.dropFirst())."
        }
        return OrphanBannerText(
            title: title, message: message, showsTurnOff: changeable.contains(where: \.isEnabled),
            showsRemove: !changeable.isEmpty)
    }

    // MARK: issues

    /// What couldn't be read, in plain words: at most three, then "and N more".
    public static func issueSummary(_ issues: [ScanIssue], home: String) -> String {
        let lines = issues.prefix(3).map { issue -> String in
            switch issue {
            case .missingFullDiskAccess(let url):
                return "\(HistoryScreen.shortened(url.path(percentEncoded: false), home: home)) needs Full Disk Access"
            case .unreadable(let url):
                return "\(HistoryScreen.shortened(url.path(percentEncoded: false), home: home)) couldn't be read"
            case .commandFailed(let command, let reason):
                return "\(command) failed: \(reason)"
            }
        }
        let more = issues.count > 3 ? ", and \(issues.count - 3) more" : ""
        return lines.joined(separator: ". ") + more + "."
    }

    // MARK: remove

    public struct RemoveConfirmText: Equatable, Sendable {
        public let title: String
        public let message: String
        public let limitedNote: String?
        public let button: String
    }

    public static func removeConfirm(name: String, canTakeOutOfTrash: Bool) -> RemoveConfirmText {
        let stops = "It stops now and won't start at your next login."
        return RemoveConfirmText(
            title: "Move \(name) to the Trash?",
            message: canTakeOutOfTrash ? stops + " You can put it back from History until you empty the Trash." : stops,
            limitedNote: canTakeOutOfTrash ? nil : CleanupGate.limitedNote,
            button: "Move to Trash")
    }

    // MARK: what a change did

    public enum Action: Equatable, Sendable { case toggle, remove }

    public struct ChangeResult: Equatable, Sendable {
        public let success: Bool
        public let title: String
        public let message: String?
    }

    /// What the banner says after a switch or a remove, from the saved record (never from the plan).
    /// `stoppedFirst`: a remove booted the agent out before moving it, so if the move failed it is
    /// stopped now but comes back at the next login.
    public static func changeResult(
        _ record: RunRecord, name: String, action: Action, stoppedFirst: Bool = false
    ) -> ChangeResult {
        let problems = record.entries.compactMap { entry -> String? in
            switch entry.outcome {
            case .failed(let reason): return reason
            case .needsAdmin: return helperNote
            case .skipped(let reason) where !OutcomePresentation.isSuccessfulToggle(entry.outcome, in: record.kind):
                return reason
            default: return nil
            }
        }
        let message = problems.isEmpty ? nil : problems.joined(separator: ". ")
        switch action {
        case .toggle:
            if let done = record.entries.first(where: { OutcomePresentation.isSuccessfulToggle($0.outcome, in: record.kind) }) {
                let what = OutcomePresentation.text(done.outcome, in: record.kind)
                return ChangeResult(success: problems.isEmpty, title: "\(what) \(name).", message: message)
            }
            return ChangeResult(success: false, title: "\(name) wasn't changed.", message: message)
        case .remove:
            let moved = record.entries.contains { if case .movedToTrash = $0.outcome { true } else { false } }
            if moved {
                return ChangeResult(
                    success: problems.isEmpty,
                    title: problems.isEmpty ? "Moved \(name) to the Trash." : "Moved \(name) to the Trash, with a problem.",
                    message: message)
            }
            let comesBack = "It was stopped but will start again at your next login."
            let full = stoppedFirst ? [message.map { $0.hasSuffix(".") ? $0 : $0 + "." }, comesBack].compactMap { $0 }.joined(separator: " ") : message
            return ChangeResult(success: false, title: "\(name) wasn't moved.", message: full)
        }
    }
}
