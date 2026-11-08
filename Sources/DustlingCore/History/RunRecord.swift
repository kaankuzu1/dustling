import Foundation

public enum RunKind: Codable, Equatable, Sendable {
    case junkClean
    case uninstall(appName: String)
    case emptyTrash
    case startupChange
}

/// Who the trashed item is, captured with `lstat` right after the move. A restore only moves an item
/// back if the thing at the trashed path is still this one (the Trash may have been emptied and the
/// name reused by a later run).
public struct TrashedIdentity: Codable, Equatable, Sendable {
    public var dev: UInt64
    public var ino: UInt64
    /// Birth time in seconds since 1970.
    public var birthtime: Double

    public init(dev: UInt64, ino: UInt64, birthtime: Double) {
        self.dev = dev
        self.ino = ino
        self.birthtime = birthtime
    }

    /// The identity of whatever is at `path` (not following a final symlink), or nil if it can't be read.
    public static func of(path: String) -> TrashedIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let birth = Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) / 1_000_000_000
        return TrashedIdentity(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino), birthtime: birth)
    }

    /// Same file: device and inode equal and the birth time equal (within JSON rounding).
    public func isSameItem(as other: TrashedIdentity) -> Bool {
        dev == other.dev && ino == other.ino && abs(birthtime - other.birthtime) < 0.000_01
    }
}

public struct JournalEntry: Codable, Equatable, Sendable {
    public var originalPath: String
    public var bytes: UInt64
    public var outcome: DeletionOutcome
    public var restored: Bool
    /// Captured right after a successful move to the Trash. Nil in records written before it existed.
    public var trashedIdentity: TrashedIdentity?
    /// The trashed item is known to be gone for good (something else took its place in the Trash),
    /// so this entry can never be restored again.
    public var gone: Bool

    public init(
        originalPath: String, bytes: UInt64, outcome: DeletionOutcome, restored: Bool = false,
        trashedIdentity: TrashedIdentity? = nil, gone: Bool = false
    ) {
        self.originalPath = originalPath
        self.bytes = bytes
        self.outcome = outcome
        self.restored = restored
        self.trashedIdentity = trashedIdentity
        self.gone = gone
    }

    private enum CodingKeys: String, CodingKey {
        case originalPath, bytes, outcome, restored, trashedIdentity, gone
    }

    /// Tolerates records written before `trashedIdentity` and `gone` existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originalPath = try c.decode(String.self, forKey: .originalPath)
        bytes = try c.decode(UInt64.self, forKey: .bytes)
        outcome = try c.decode(DeletionOutcome.self, forKey: .outcome)
        restored = try c.decode(Bool.self, forKey: .restored)
        trashedIdentity = try c.decodeIfPresent(TrashedIdentity.self, forKey: .trashedIdentity)
        gone = try c.decodeIfPresent(Bool.self, forKey: .gone) ?? false
    }
}

public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var kind: RunKind
    public var entries: [JournalEntry]
    public var restorable: Bool
    /// True while a cleanup is running (the journal is saved after every item). A record still
    /// marked this way after the process is gone was interrupted; see `CleanupRunner.recoverInterrupted`.
    public var inProgress: Bool

    public init(
        id: UUID = UUID(), startedAt: Date, kind: RunKind, entries: [JournalEntry], restorable: Bool,
        inProgress: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.kind = kind
        self.entries = entries
        self.restorable = restorable
        self.inProgress = inProgress
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, kind, entries, restorable, inProgress
    }

    /// Tolerates records written before `inProgress` existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        kind = try c.decode(RunKind.self, forKey: .kind)
        entries = try c.decode([JournalEntry].self, forKey: .entries)
        restorable = try c.decode(Bool.self, forKey: .restorable)
        inProgress = try c.decodeIfPresent(Bool.self, forKey: .inProgress) ?? false
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
