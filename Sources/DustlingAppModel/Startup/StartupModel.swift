import DustlingCore
import Foundation
import Observation

public enum StartupGroupKind: String, CaseIterable, Sendable {
    case loginItems, agents, daemons

    public var title: String {
        switch self {
        case .loginItems: "Login items"
        case .agents: "Agents"
        case .daemons: "Daemons"
        }
    }

    static func of(_ scope: StartupScope) -> StartupGroupKind {
        switch scope {
        case .loginItem: .loginItems
        case .userAgent, .systemAgent: .agents
        case .systemDaemon: .daemons
        }
    }
}

public enum StartupFilter: Sendable, CaseIterable {
    case all, on, off
}

public struct StartupRow: Identifiable, Equatable, Sendable {
    public let item: StartupItem
    /// "Needs the cleanup helper" for system items; nil otherwise.
    public let chip: String?
    /// False when the switch is shown disabled.
    public let canToggle: Bool
    /// Login items are changed only in System Settings; the row shows that link.
    public let showsSystemSettingsLink: Bool
    public let isOrphaned: Bool
    public var id: String { item.id }
}

public struct StartupGroup: Identifiable, Equatable, Sendable {
    public let kind: StartupGroupKind
    /// The rows that pass the group's filter.
    public let rows: [StartupRow]
    public let onCount: Int
    public let total: Int
    public let filter: StartupFilter
    public var id: StartupGroupKind { kind }
    public var title: String { kind.title }
    /// "3/5".
    public var countText: String { "\(onCount)/\(total)" }
}

public struct OrphanBanner: Equatable, Sendable {
    public let items: [StartupItem]
    public let message: String
}

/// Drives the Startup items screen: login items, agents and daemons with on/off switches.
@MainActor @Observable
public final class StartupModel {
    public static let helperChip = "Needs the cleanup helper"

    public private(set) var items: [StartupItem] = []
    public private(set) var issues: [ScanIssue] = []
    public private(set) var isLoading = false
    /// What the last switch did, in plain words ("Turned off X"); nil before any.
    public private(set) var lastChange: String?
    /// Computed once per `load()` so reading `groups` never touches the disk.
    public private(set) var orphanBanner: OrphanBanner?
    @ObservationIgnored private var orphanIDs: Set<String> = []
    public private(set) var filters: [StartupGroupKind: StartupFilter] = [:]

    @ObservationIgnored private let scanner: StartupItemScanner
    @ObservationIgnored private let recorder: StartupChangeRecorder
    @ObservationIgnored private let fileExists: @Sendable (String) -> Bool
    @ObservationIgnored private let onRunCompleted: @MainActor () -> Void
    @ObservationIgnored private var generation = 0

    public init(
        scanner: StartupItemScanner, recorder: StartupChangeRecorder,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.scanner = scanner
        self.recorder = recorder
        self.fileExists = fileExists
        self.onRunCompleted = onRunCompleted
    }

    public func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        let scanner = self.scanner, fileExists = self.fileExists
        let found = await Task.detached(priority: .userInitiated) { () -> ([StartupItem], [ScanIssue], [StartupItem]) in
            let scanned = scanner.scanWithIssues()
            // Only an absolute program path can be judged; a bare name is looked up on PATH at launch.
            let orphans = scanned.items.filter { item in
                guard let program = item.program, program.hasPrefix("/") else { return false }
                return !fileExists(program)
            }
            return (scanned.items, scanned.issues, orphans)
        }.value
        guard mine == generation else { return }
        isLoading = false
        items = found.0
        issues = found.1
        orphanIDs = Set(found.2.map(\.id))
        if found.2.isEmpty {
            orphanBanner = nil
        } else {
            let one = found.2.count == 1
            orphanBanner = OrphanBanner(
                items: found.2,
                message: "\(found.2.count) startup \(one ? "item" : "items") point to an app or file that is gone. Turning \(one ? "it" : "them") off is safe.")
        }
    }

    public func setFilter(_ filter: StartupFilter, for kind: StartupGroupKind) {
        filters[kind] = filter
    }

    public var groups: [StartupGroup] {
        StartupGroupKind.allCases.map { kind in
            let all = items.filter { StartupGroupKind.of($0.scope) == kind }
            let filter = filters[kind] ?? .all
            let shown = all.filter {
                switch filter {
                case .all: true
                case .on: $0.isEnabled
                case .off: !$0.isEnabled
                }
            }
            return StartupGroup(
                kind: kind, rows: shown.map(row(for:)), onCount: all.filter(\.isEnabled).count,
                total: all.count, filter: filter)
        }
    }

    func row(for item: StartupItem) -> StartupRow {
        let needsHelper = item.scope == .systemDaemon || item.scope == .systemAgent
        let loginOnly = item.scope == .loginItem || item.managedInSystemSettingsOnly
        return StartupRow(
            item: item, chip: needsHelper ? Self.helperChip : nil,
            canToggle: !needsHelper && !loginOnly, showsSystemSettingsLink: loginOnly,
            isOrphaned: orphanIDs.contains(item.id))
    }

    /// Turns `item` on or off (the opposite of how it is now) and records it in History. The engine
    /// decides whether it can: a system item comes back `Needs the cleanup helper`.
    public func toggle(_ item: StartupItem) async -> RunRecord {
        let recorder = self.recorder
        let target = !item.isEnabled
        let record = await Task.detached(priority: .userInitiated) { recorder.setEnabled(item, target) }.value
        if let entry = record.entries.first {
            let what = OutcomePresentation.text(entry.outcome, in: record.kind)
            lastChange = OutcomePresentation.isSuccessfulToggle(entry.outcome, in: record.kind)
                ? "\(what) \(item.label)" : "\(item.label): \(what)"
        }
        await load()
        onRunCompleted()
        return record
    }
}
