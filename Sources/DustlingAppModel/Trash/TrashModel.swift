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

/// What Empty Trash could not delete, counted by cause, for the sheet to say so in plain words.
public struct EmptyTrashProblems: Equatable, Sendable {
    /// Belong to another account (the system, an installer): only the Mac password deletes them.
    public let needsAdmin: Int
    /// Protected by macOS.
    public let protected: Int
    /// Failed for another reason; the log has it.
    public let failed: Int
    /// No longer in the Trash: the password step stopped while they were on their way out, because
    /// something changed (`AdminScript.heldReason`). They are untouched in `keptIn`.
    public let heldAside: Int
    /// No longer in the Trash: macOS refused to delete part of them, even with the password
    /// (`AdminScript.partlyDeletedReason`). What is left is in `keptIn`.
    public let partlyDeleted: Int
    /// The hidden folder in /Library that holds `heldAside` and `partlyDeleted` items, as the
    /// password step named it (nil when there are none).
    public let keptIn: String?

    public init(
        needsAdmin: Int, protected: Int, failed: Int, heldAside: Int = 0, partlyDeleted: Int = 0, keptIn: String? = nil
    ) {
        self.needsAdmin = needsAdmin
        self.protected = protected
        self.failed = failed
        self.heldAside = heldAside
        self.partlyDeleted = partlyDeleted
        self.keptIn = keptIn
    }

    /// Nil when the run left nothing behind. The `<history>` / `<log>` markers are not Trash items.
    public static func of(_ record: RunRecord) -> EmptyTrashProblems? {
        var admin = 0, protected = 0, failed = 0, held = 0, partly = 0
        var keptIn: String?
        for entry in record.entries where !entry.originalPath.hasPrefix("<") && !TrashInspector.isLocationFailure(entry) {
            switch entry.outcome {
            case .needsAdmin:
                admin += 1
            case .failed(let reason):
                if reason == TrashUnlocker.protectedReason {
                    protected += 1
                } else if let folder = Self.folder(in: reason, after: AdminScript.heldPrefix) {
                    held += 1
                    keptIn = keptIn ?? folder
                } else if let folder = Self.folder(in: reason, after: AdminScript.partlyDeletedPrefix) {
                    partly += 1
                    keptIn = keptIn ?? folder
                } else {
                    failed += 1
                }
            default:
                break
            }
        }
        guard admin + protected + failed + held + partly > 0 else { return nil }
        return EmptyTrashProblems(
            needsAdmin: admin, protected: protected, failed: failed, heldAside: held, partlyDeleted: partly, keptIn: keptIn)
    }

    /// The folder a kept-aside reason names: what follows `prefix`, without the final period.
    private static func folder(in reason: String, after prefix: String) -> String? {
        guard reason.hasPrefix(prefix) else { return nil }
        var folder = String(reason.dropFirst(prefix.count))
        if folder.hasSuffix(".") { folder.removeLast() }
        return folder.isEmpty ? nil : folder
    }

    /// How many items Empty Trash left.
    public var total: Int { needsAdmin + protected + failed + heldAside + partlyDeleted }

    /// The sheet's title once some items could not be deleted. Items kept aside in /Library are
    /// no longer in the Trash, so then it doesn't say they are.
    public var title: String {
        if heldAside + partlyDeleted > 0 {
            return total == 1 ? "1 item wasn't deleted" : "\(total) items weren't deleted"
        }
        return total == 1 ? "1 item is still in the Trash" : "\(total) items are still in the Trash"
    }

    public var message: String {
        var parts: [String] = []
        let folder = keptIn ?? "a hidden folder in /Library"
        if needsAdmin > 0 {
            parts.append("\(Self.count(needsAdmin, "item belongs", "items belong")) to the system. Empty Trash again and enter your Mac password, or empty the Trash in Finder.")
        }
        if protected > 0 {
            parts.append("\(Self.count(protected, "item is", "items are")) protected by macOS and can't be deleted.")
        }
        if heldAside > 0 {
            parts.append(heldAside == 1
                ? "1 item stopped on its way out of the Trash because something changed. It is untouched in \(folder)."
                : "\(heldAside) items stopped on their way out of the Trash because something changed. They are untouched in \(folder).")
        }
        if partlyDeleted > 0 {
            parts.append("macOS refused to delete part of \(Self.count(partlyDeleted, "item", "items")), even with your password. What is left of \(partlyDeleted == 1 ? "it" : "them") is in \(folder).")
        }
        if failed > 0 {
            parts.append("\(Self.count(failed, "item", "items")) couldn't be deleted. The log has the reason for each.")
        }
        return parts.joined(separator: " ")
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
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
    /// Settings > Include Trash on external drives. Applies only with Full Disk Access; leaving other
    /// volumes out by choice is not "skipped" (nothing is shown as locked).
    @ObservationIgnored public var includeExternalVolumes = true
    /// How many places inside the Trash belong to another account (the system) and couldn't be read
    /// (`TrashContents.systemUnreadable`): Empty Trash still works (it deletes them with the Mac
    /// password), but the size leaves out what is inside them.
    public private(set) var unreadableSystemItems = 0

    /// The size shown is only part of the Trash: other volumes weren't looked at, or some items that
    /// belong to the system couldn't be read. Show it as "or more".
    public var sizeIsLowerBound: Bool { externalVolumesSkipped || unreadableSystemItems > 0 }

    /// Builds the inspector for one refresh: `true` includes other volumes' Trash folders. Called on
    /// the main actor, so the app can give it the password step that applies now.
    @ObservationIgnored private let makeInspector: @MainActor (_ includeExternalVolumes: Bool) -> TrashInspector
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
    /// Empty Trash deletes with the inspector the last refresh built, and so with its `admin`.
    public init(
        makeInspector: @escaping @MainActor (_ includeExternalVolumes: Bool) -> TrashInspector, journal: RunJournal,
        onRunCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.makeInspector = makeInspector
        self.inspector = makeInspector(false)
        self.journal = journal
        self.onRunCompleted = onRunCompleted
    }

    /// False until the Trash has been read, when a trash location (or, for lack of Full Disk Access, an
    /// item) is unreadable, and when it holds nothing. Items of another account that can't be read
    /// don't count: Empty Trash deletes them with the Mac password.
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
        #if DEBUG
        guard !isFixture else { return }
        #endif
        generation += 1
        let mine = generation
        let access = lastAccess
        let external = access && includeExternalVolumes
        let inspector = makeInspector(external)
        let journal = self.journal
        let found = await Blocking.run { () -> Snapshot in
            let found = inspector.contents()
            return Snapshot(sized: (found.size, found.issues), items: found.items,
                            systemUnreadable: found.systemUnreadable.count, inTrash: Self.inTrashBytes(journal))
        }
        guard mine == generation else { return }
        self.inspector = inspector
        externalVolumesSkipped = !access
        unreadableSystemItems = found.systemUnreadable
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
        #if DEBUG
        guard !isFixture else { return .refused(reason: "This is a screenshot sample, so nothing was deleted.") }
        #endif
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

    #if DEBUG
    /// The DEBUG screenshot fixture is showing: the Trash is never read or emptied.
    @ObservationIgnored public private(set) var isFixture = false

    /// Screenshot fixture (DEBUG only): shows these items as the Trash, read in full, without
    /// looking at the disk. Refresh and Empty Trash do nothing from then on.
    /// `unreadableAt`: the Trash reads as locked there instead (as without Full Disk Access).
    public func showFixture(items: [TrashItem], inTrashBytes: UInt64, unreadableAt: URL? = nil) {
        isFixture = true
        generation += 1
        let bytes = items.reduce(UInt64(0)) { $0 + $1.size.bytes }
        let files = items.reduce(0) { $0 + $1.size.fileCount }
        contents = (SizeResult(bytes: bytes, fileCount: files), unreadableAt.map { [.missingFullDiskAccess($0)] } ?? [])
        self.items = items
        externalVolumesSkipped = unreadableAt != nil
        unreadableSystemItems = 0
        inTrashBytesSinceLastEmpty = inTrashBytes
        historyProblem = nil
    }

    /// Screenshot fixture: Empty Trash is running (it never finishes; nothing is deleted).
    public func showFixtureEmptying() {
        guard isFixture else { return }
        isEmptying = true
    }
    #endif

    private struct Snapshot: Sendable {
        let sized: (size: SizeResult, issues: [ScanIssue])
        let items: [TrashItem]
        let systemUnreadable: Int
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
