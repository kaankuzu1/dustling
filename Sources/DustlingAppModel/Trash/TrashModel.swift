import DustlingCore
import Foundation
import Observation

/// The Trash as the Empty Trash button and the storage mosaic need it.
///
/// Sizing the Trash is blocking filesystem work, so `refresh()` runs it off the main actor and
/// publishes the result here; a slower older refresh never overwrites a newer one.
public enum EmptyTrashResult: Sendable {
    case emptied(RunRecord)
    /// Nothing was deleted; `reason` is in plain words. When the Trash changed since it was
    /// confirmed, the model has already refreshed, so the UI can show the new size and ask again.
    case refused(reason: String)
}

@MainActor @Observable
public final class TrashModel {
    /// Nil until the first `refresh()`.
    public private(set) var contents: (size: SizeResult, issues: [ScanIssue])?
    /// The top-level items the last refresh found, for the Empty Trash sheet. Empty until then.
    public private(set) var items: [TrashItem] = []
    /// Bytes Dustling moved to the Trash that can still be put back (from the journal): the
    /// hatched "in Trash" cells of the mosaic. Drops as items are restored or the Trash is emptied.
    public private(set) var inTrashBytesSinceLastEmpty: UInt64 = 0
    /// Set when the history could not be read, so the in-Trash number may be missing runs.
    public private(set) var historyProblem: String?

    /// True when the last refresh looked only at `~/.Trash`: without Full Disk Access the Trash folders
    /// on other volumes are never opened (a removable or network volume can ask for consent). Their
    /// contents are then unknown, so show them as locked and totals as a lower bound.
    public private(set) var externalVolumesSkipped = false

    /// Builds the inspector for one refresh: `true` includes other volumes' Trash folders.
    @ObservationIgnored private let makeInspector: @Sendable (_ includeExternalVolumes: Bool) -> TrashInspector
    /// The inspector the shown contents came from; Empty Trash re-reads and empties with the same one.
    @ObservationIgnored private var inspector: TrashInspector
    @ObservationIgnored private let journal: RunJournal
    @ObservationIgnored private let onRunCompleted: @MainActor () -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastAccess = false
    public private(set) var isEmptying = false

    public convenience init(
        inspector: TrashInspector, journal: RunJournal, onRunCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.init(makeInspector: { _ in inspector }, journal: journal, onRunCompleted: onRunCompleted)
    }

    /// `makeInspector(true)` must include other volumes' Trash folders, `makeInspector(false)` only `~/.Trash`.
    public init(
        makeInspector: @escaping @Sendable (_ includeExternalVolumes: Bool) -> TrashInspector, journal: RunJournal,
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.makeInspector = makeInspector
        self.inspector = makeInspector(false)
        self.journal = journal
        self.onRunCompleted = onRunCompleted
    }

    /// False until the Trash has been read, when any trash location is unreadable, and when it holds nothing.
    public var canEmpty: Bool { disabledReason == nil }

    /// Why Empty Trash is off, in plain words; nil when it is available.
    public var disabledReason: String? {
        guard let contents else { return "Dustling hasn't looked in the Trash yet" }
        if !contents.issues.isEmpty {
            let noAccess = contents.issues.contains { if case .missingFullDiskAccess = $0 { true } else { false } }
            return noAccess
                ? "Dustling can't see inside the Trash without Full Disk Access"
                : "Dustling can't read part of the Trash, so it won't empty it"
        }
        if contents.size.bytes == 0 { return "The Trash is empty" }
        return nil
    }

    /// Re-reads the Trash. Without Full Disk Access only `~/.Trash` is looked at.
    public func refresh(fullDiskAccessGranted: Bool) async {
        lastAccess = fullDiskAccessGranted
        await refresh()
    }

    /// Re-reads the Trash with the access the last `refresh(fullDiskAccessGranted:)` reported
    /// (none until then: only `~/.Trash`).
    public func refresh() async {
        generation += 1
        let mine = generation
        let external = lastAccess
        let inspector = makeInspector(external)
        let journal = self.journal
        let found = await Blocking.run { () -> Snapshot in
            let found = inspector.contents()
            return Snapshot(sized: (found.size, found.issues), items: found.items, inTrash: Self.inTrashBytes(journal))
        }
        guard mine == generation else { return }
        self.inspector = inspector
        externalVolumesSkipped = !external
        contents = found.sized
        items = found.items
        inTrashBytesSinceLastEmpty = found.inTrash.bytes
        historyProblem = found.inTrash.problem
    }

    /// Permanently deletes everything in the Trash. The UI confirms first and passes the size it
    /// showed (`confirmedBytes`); this is the only way the app empties it. Refuses (nothing deleted)
    /// when `canEmpty` is false, when another empty is running, when the size the user confirmed is
    /// not the size last read, and when the Trash was re-read just before deleting and is no longer
    /// what was confirmed (unreadable, or a different size).
    public func emptyTrash(confirmedBytes confirmed: UInt64) async -> EmptyTrashResult {
        guard !isEmptying else { return .refused(reason: "The Trash is already being emptied") }
        guard canEmpty, let shown = contents?.size.bytes else {
            return .refused(reason: disabledReason ?? "The Trash can't be emptied")
        }
        guard shown == confirmed else {
            return .refused(reason: "The Trash changed since you looked at it. Check it again before emptying.")
        }
        isEmptying = true
        defer { isEmptying = false }
        let inspector = self.inspector
        let attempt = await Blocking.run { () -> RunRecord? in
            let now = inspector.sizeWithIssues()
            guard now.issues.isEmpty, now.size.bytes == confirmed else { return nil }
            return inspector.emptyTrash()
        }
        await refresh()
        guard let record = attempt else {
            return .refused(reason: "The Trash changed since you looked at it. Check it again before emptying.")
        }
        onRunCompleted()
        return .emptied(record)
    }

    private struct Snapshot: Sendable {
        let sized: (size: SizeResult, issues: [ScanIssue])
        let items: [TrashItem]
        let inTrash: (bytes: UInt64, problem: String?)
    }

    private nonisolated static func inTrashBytes(_ journal: RunJournal) -> (bytes: UInt64, problem: String?) {
        do {
            let bytes = try journal.all().reduce(UInt64(0)) { sum, run in
                guard run.restorable else { return sum }
                return run.entries.reduce(sum) { $0 + (RunJournal.isRestorable($1) ? $1.bytes : 0) }
            }
            return (bytes, nil)
        } catch {
            return (0, "Dustling couldn't read its history, so the 'in Trash' amount may be missing.")
        }
    }
}
