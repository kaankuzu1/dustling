import Foundation

public enum RunKind: Codable, Equatable, Sendable {
    case junkClean
    case uninstall(appName: String)
    case emptyTrash
    case startupChange
}

public struct JournalEntry: Codable, Equatable, Sendable {
    public var originalPath: String
    public var bytes: UInt64
    public var outcome: DeletionOutcome
    public var restored: Bool

    public init(originalPath: String, bytes: UInt64, outcome: DeletionOutcome, restored: Bool = false) {
        self.originalPath = originalPath
        self.bytes = bytes
        self.outcome = outcome
        self.restored = restored
    }
}

public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var kind: RunKind
    public var entries: [JournalEntry]
    public var restorable: Bool

    public init(id: UUID = UUID(), startedAt: Date, kind: RunKind, entries: [JournalEntry], restorable: Bool) {
        self.id = id
        self.startedAt = startedAt
        self.kind = kind
        self.entries = entries
        self.restorable = restorable
    }

    public var bytesMovedToTrash: UInt64 {
        entries.reduce(0) { sum, e in
            if case .movedToTrash = e.outcome { return sum + e.bytes }
            return sum
        }
    }

    public var failedCount: Int {
        entries.filter { if case .failed = $0.outcome { true } else { false } }.count
    }

    public var needsAdminCount: Int {
        entries.filter { $0.outcome == .needsAdmin }.count
    }

    public var skippedCount: Int {
        entries.filter { if case .skipped = $0.outcome { true } else { false } }.count
    }
}

public enum RestoreOutcome: Equatable, Sendable {
    case restored(String)
    case conflict(String)
    case missingFromTrash(String)
    case failed(String, reason: String)
}
