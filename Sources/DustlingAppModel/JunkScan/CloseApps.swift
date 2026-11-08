import DustlingCore
import Foundation
import Observation

/// A regular app running right now (the app target lists them from `NSWorkspace`: only apps with a
/// Dock presence and a bundle, never Dustling itself or background processes).
public struct RunningApp: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let bundleURL: URL

    public init(bundleID: String, name: String, bundleURL: URL) {
        self.bundleID = bundleID
        self.name = name
        self.bundleURL = bundleURL
    }
}

/// An open app that holds files the cleanup would otherwise move.
public struct OpenAppHolder: Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let bundleURL: URL
    /// Its junk that is selected and waiting for it to close.
    public let bytes: UInt64
    public let itemCount: Int

    public init(bundleID: String, name: String, bundleURL: URL, bytes: UInt64, itemCount: Int) {
        self.bundleID = bundleID
        self.name = name
        self.bundleURL = bundleURL
        self.bytes = bytes
        self.itemCount = itemCount
    }
}

/// The words of the "close open apps" sheet and the summary.
public enum CloseApps {
    public static let note = "Dustling asks each app to quit, like pressing ⌘Q, so it can save your work and tabs. "
        + "It never forces an app to quit."
    /// How long to wait for each app, as for uninstalling.
    public static let timeout: Duration = .seconds(10)

    /// One row per open app (32 pt icon in a 48 pt row); five show before the list scrolls.
    public static let rowHeight: Double = 48
    public static let visibleRows = 5

    public static func list(holders: Int) -> SheetList {
        SheetList(rows: holders, rowHeight: rowHeight, spacing: 0, maxVisible: visibleRows)
    }

    public static func title(_ holders: [OpenAppHolder]) -> String {
        holders.count == 1
            ? "Close \(holders[0].name) to include its files?"
            : "Close \(holders.count) apps to include their files?"
    }

    /// "Closed Safari and Slack before cleaning." nil when no app was closed.
    public static func summaryLine(_ names: [String]) -> String? {
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return "Closed \(list) before cleaning."
    }

    public enum Status: Equatable, Sendable { case waiting, closing, closed, stillOpen }

    public static func statusText(_ status: Status) -> String {
        switch status {
        case .waiting: ""
        case .closing: "Closing…"
        case .closed: "Closed"
        case .stillOpen: "Still open, its files will stay"
        }
    }

    /// Said when what can move isn't what the sheet offered: because apps stayed open, or because
    /// files changed meanwhile.
    public static func changedLine(promised: UInt64, now: UInt64, someStillOpen: Bool) -> String? {
        guard now != promised else { return nil }
        let figures = "\(Bytes.format(now)) will move instead of \(Bytes.format(promised))."
        return someStillOpen && now < promised
            ? "Some apps stayed open, so their files stay where they are. " + figures
            : "What can move changed while the apps closed. " + figures
    }

    /// What the post-quit flow decided.
    public enum FlowResult: Equatable, Sendable {
        /// Every offered file can move: the cleanup ran.
        case cleaned
        /// What can move changed: show `line` and ask again with `now`.
        case askAgain(now: UInt64, line: String)
    }
}

/// Asks each app to quit (never forces it) and tracks how each one went, live.
@MainActor @Observable
public final class CloseAppsRun: Identifiable {
    public let holders: [OpenAppHolder]
    public private(set) var statuses: [String: CloseApps.Status]

    public init(holders: [OpenAppHolder]) {
        self.holders = holders
        statuses = Dictionary(uniqueKeysWithValues: holders.map { ($0.bundleID, CloseApps.Status.waiting) })
    }

    public var isFinished: Bool { statuses.values.allSatisfy { $0 == .closed || $0 == .stillOpen } }
    public var isRunning: Bool { statuses.values.contains(.closing) }

    /// The names of the apps that closed, in list order.
    public var closedNames: [String] { holders.filter { statuses[$0.bundleID] == .closed }.map(\.name) }

    /// Asks every app at once and waits at most `timeout` for each.
    public func quitAll(using quitter: AppQuitter, timeout: Duration = CloseApps.timeout) async {
        for holder in holders { statuses[holder.bundleID] = .closing }
        await withTaskGroup(of: (String, Bool).self) { group in
            for holder in holders {
                let app = InstalledApp(
                    url: holder.bundleURL, displayName: holder.name, bundleID: holder.bundleID, teamID: nil,
                    executableName: nil, steamAppID: nil, bytes: 0, lastUsed: nil)
                group.addTask {
                    (holder.bundleID, await UninstallerModel.quitWithTimeout(app, quit: quitter, timeout: timeout))
                }
            }
            for await (id, closed) in group {
                statuses[id] = closed ? .closed : .stillOpen
            }
        }
    }

    /// After the re-check: an app that didn't answer in time but isn't running any more did close.
    func settle(running: Set<String>) {
        for holder in holders where statuses[holder.bundleID] == .stillOpen && !running.contains(holder.bundleID) {
            statuses[holder.bundleID] = .closed
        }
    }
}
