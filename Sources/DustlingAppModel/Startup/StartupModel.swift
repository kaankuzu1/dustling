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
    @ObservationIgnored private let presence: @Sendable (String) -> ProgramPresence
    @ObservationIgnored private let onRunCompleted: @MainActor () -> Void
    @ObservationIgnored private var generation = 0

    public init(
        scanner: StartupItemScanner, recorder: StartupChangeRecorder,
        presence: @escaping @Sendable (String) -> ProgramPresence = ProgramPresence.check,
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.scanner = scanner
        self.recorder = recorder
        self.presence = presence
        self.onRunCompleted = onRunCompleted
    }

    /// Reads the startup items and judges which point to a program that is gone. Programs under
    /// `unjudged` (folders that ask for consent without Full Disk Access, and other volumes) are never
    /// looked at, so loading can't raise a prompt; they are simply not called orphans.
    public func load(unjudged: [URL] = []) async {
        generation += 1
        let mine = generation
        isLoading = true
        let scanner = self.scanner, presence = self.presence
        let found = await Blocking.run { () -> ([StartupItem], [ScanIssue], [StartupItem]) in
            let scanned = scanner.scanWithIssues()
            let orphans = scanned.items.filter {
                ProgramPresence.isOrphan($0.program, unjudged: unjudged, presence: presence)
            }
            return (scanned.items, scanned.issues, orphans)
        }
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
        let record = await Blocking.run { recorder.setEnabled(item, target) }
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

/// Whether a startup item's program is still on disk.
public enum ProgramPresence: Equatable, Sendable {
    case present
    /// `lstat` said ENOENT or ENOTDIR: the program is gone.
    case missing
    /// It couldn't be looked at (EPERM, EACCES, …). Never counted as gone.
    case unknown

    /// Folders whose programs aren't looked at when judging startup items without Full Disk Access:
    /// the consent folders, iCloud Drive (`~/Library/Mobile Documents`) and other volumes. Looking
    /// there could raise a prompt. With access, everything is judged.
    public static func unjudgedFolders(_ environment: SystemEnvironment, fullDiskAccessGranted: Bool) -> [URL] {
        guard !fullDiskAccessGranted else { return [] }
        return PlaceAccessChecker.consentFolders(environment)
            + [environment.userLibrary.appending(path: "Mobile Documents"), URL(filePath: "/Volumes")]
    }

    public static func check(_ path: String) -> ProgramPresence {
        var info = stat()
        if lstat(path, &info) == 0 { return .present }
        switch errno {
        case ENOENT, ENOTDIR: return .missing
        default: return .unknown
        }
    }

    /// Only an absolute program path can be judged (a bare name is looked up on PATH at launch), and
    /// only outside `unjudged`. Orphaned only when the program is known to be missing.
    public static func isOrphan(
        _ program: String?, unjudged: [URL], presence: (String) -> ProgramPresence
    ) -> Bool {
        guard let program, program.hasPrefix("/") else { return false }
        let path = URL(filePath: program).standardizedFileURL.pathComponents
        for folder in unjudged {
            let prefix = folder.standardizedFileURL.pathComponents
            if path.count >= prefix.count && Array(path.prefix(prefix.count)) == prefix { return false }
        }
        return presence(program) == .missing
    }
}
