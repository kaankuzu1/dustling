import Foundation

/// The single path every cleanup and uninstall goes through: measure, trash, record, journal, log.
public struct CleanupRunner: Sendable {
    private let mover: TrashMover
    private let journal: RunJournal
    private let logger: RunLogger
    private let sizer: DirectorySizer
    /// Moves what belongs to the system with the Mac password, or nil (the CLI): such items are then
    /// recorded as needing admin and never attempted.
    let admin: AdminMover?

    /// The guard every move goes through; other code that acts before moving (e.g. booting out a launch
    /// agent) must use this one so it can't disagree with the mover.
    public var protectedPaths: ProtectedPaths { mover.protectedPaths }

    /// `admin`: pass one only when Dustling has Full Disk Access (planning must open `~/.Trash`).
    /// Without it nothing asks for the password and every run behaves as before.
    public init(
        mover: TrashMover, journal: RunJournal, logger: RunLogger, sizer: DirectorySizer, admin: AdminMover? = nil
    ) {
        self.mover = mover
        self.journal = journal
        self.logger = logger
        self.sizer = sizer
        self.admin = admin
    }

    /// This runner with `admin` in place of its own: the app decides per action whether the password
    /// step may run (only while Dustling has Full Disk Access). nil: nothing asks for the password.
    public func with(admin: AdminMover?) -> CleanupRunner {
        CleanupRunner(mover: mover, journal: journal, logger: logger, sizer: sizer, admin: admin)
    }

    /// `extraEntries` (e.g. launch-agent unload failures) are appended after the runner's own entries.
    /// A journal or log failure is recorded once, as a failed `<history>` / `<log>` entry in the record
    /// (at the point it happened, so it is also journaled and returned); the run then carries on.
    ///
    /// The journal is saved (atomically) and the log appended after EVERY item, with the record marked
    /// `inProgress` until the end, so a crash is recorded up to the last finished item
    /// (`recoverInterrupted` clears the flag on the next launch). On cooperative cancellation
    /// (cancelling the task is checked before each item) the items not attempted are recorded as
    /// `.skipped(reason: "cleanup stopped")` in one save, and the run ends normally with `inProgress == false`.
    /// `onItemStart` fires before each move, `onItem` after it. The work runs on a GCD queue
    /// (`FileWork`), so the callbacks arrive on that queue.
    ///
    /// With `admin`, an item that needs admin is held: neither recorded nor reported yet, its identity
    /// (owner included) taken right after the attempt. After the last item, each held item gets its
    /// name in the Trash (only now, so a later item of the run that moved the normal way can't take
    /// it) and one password box moves them all (`AdminMover.movePrompt`); then each is recorded and
    /// `onItem` fires for it, once, with what happened: moved to the Trash (with that identity, for
    /// Put back), still needing admin (it can't be renamed into the Trash, the box was closed, or
    /// Dustling can't open a folder the move needs, such as `~/.Trash` without Full Disk Access),
    /// skipped if already gone, or failed with the script's reason. A run stopped before then never
    /// asks: its held items are recorded (and reported) as `.skipped(reason: "cleanup stopped")`,
    /// ahead of the items never attempted.
    public func run(
        _ urls: [URL],
        kind: RunKind,
        allowedRoots: [URL],
        extraEntries: [JournalEntry] = [],
        onItemStart: @escaping @Sendable (URL) -> Void = { _ in },
        onItem: @escaping @Sendable (URL, DeletionOutcome) -> Void
    ) async -> RunRecord {
        await FileWork.run { isCancelled in
            runBlocking(
                urls, kind: kind, allowedRoots: allowedRoots, extraEntries: extraEntries,
                isCancelled: isCancelled, onItemStart: onItemStart, onItem: onItem)
        }
    }

    /// The run itself, synchronous. `isCancelled` replaces `Task.isCancelled`, which GCD work can't see.
    func runBlocking(
        _ urls: [URL],
        kind: RunKind,
        allowedRoots: [URL],
        extraEntries: [JournalEntry],
        isCancelled: () -> Bool,
        onItemStart: (URL) -> Void,
        onItem: (URL, DeletionOutcome) -> Void
    ) -> RunRecord {
        var record = RunRecord(startedAt: Date(), kind: kind, entries: [], restorable: false, inProgress: true)
        var historyFailed = false
        var logFailed = false

        func save() {
            do { try journal.save(record) } catch {
                // Record the failure once; later saves are still attempted.
                if !historyFailed {
                    historyFailed = true
                    let entry = Self.failure("<history>", error)
                    record.entries.append(entry)
                    log(entry)
                }
            }
        }
        func log(_ entry: JournalEntry?) {
            guard !logFailed else { return }
            do {
                if let entry { try logger.append(entry, to: record) } else { try logger.writeHeader(record) }
            } catch {
                logFailed = true
                record.entries.append(Self.failure("<log>", error))
            }
        }
        func add(_ entry: JournalEntry) {
            record.entries.append(entry)
            if case .movedToTrash = entry.outcome { record.restorable = true }
            save()
            log(entry)
        }
        /// Entries that need no move (a stopped run's remaining items, the caller's extra in-use and
        /// unmovable entries): one save and one log write for all of them, so stopping a cleanup of
        /// thousands of items takes as long as one item, not thousands of saves.
        func addBatch(_ entries: [JournalEntry]) {
            guard !entries.isEmpty else { return }
            record.entries.append(contentsOf: entries)
            if entries.contains(where: { if case .movedToTrash = $0.outcome { true } else { false } }) {
                record.restorable = true
            }
            save()
            guard !logFailed else { return }
            do { try logger.append(entries, to: record) } catch {
                logFailed = true
                record.entries.append(Self.failure("<log>", error))
            }
        }

        log(nil)
        save()
        let stopped = DeletionOutcome.skipped(reason: "cleanup stopped")
        var held: [(url: URL, entry: JournalEntry, identity: TrashedIdentity)] = []
        var notAttempted: ArraySlice<URL> = []
        for (index, url) in urls.enumerated() {
            if isCancelled() {
                notAttempted = urls[index...]
                break
            }
            onItemStart(url)
            let entry = attempt(url, allowedRoots: allowedRoots)
            if entry.outcome == .needsAdmin, admin != nil, let identity = AdminMover.identity(of: url) {
                held.append((url, entry, identity))
                continue
            }
            add(entry)
            onItem(url, entry.outcome)
        }
        if let admin, !held.isEmpty {
            if !notAttempted.isEmpty || isCancelled() {
                addBatch(held.map { item in
                    var entry = item.entry
                    entry.outcome = stopped
                    return entry
                })
                for item in held { onItem(item.url, stopped) }
            } else {
                var taken = Set<String>()
                let moves = held.map { admin.trashMove(for: $0.url, identity: $0.identity, taken: &taken) }
                var results = admin.performOpenable(moves.compactMap { $0?.step }, prompt: AdminMover.movePrompt)
                    .makeIterator()
                for (item, move) in zip(held, moves) {
                    var entry = item.entry
                    if let move {
                        let result = results.next() ?? nil
                        entry.outcome = AdminMover.trashOutcome(result, destination: move.destination)
                        if result == .done { entry.trashedIdentity = move.identity }
                    }
                    add(entry)
                    onItem(item.url, entry.outcome)
                }
            }
        }
        addBatch(notAttempted.map {
            JournalEntry(originalPath: $0.path(percentEncoded: false), bytes: 0, outcome: stopped)
        })
        addBatch(extraEntries)

        record.inProgress = false
        save()
        if !logFailed {
            do { try logger.writeTotals(record) } catch {
                logFailed = true
                record.entries.append(Self.failure("<log>", error))
                save()
            }
        }
        return record
    }

    /// How long a run's file must have been left alone before recovery treats it as interrupted. A
    /// live run saves after every item, so one the app or the CLI is still writing is never closed.
    public static let recoveryQuietPeriod: TimeInterval = 5 * 60

    /// The quiet period to recover with: the full period while another writer (the app or the CLI)
    /// runs, none when this process is the only one, because then nothing else can still be writing.
    public static func recoveryQuietPeriod(otherWritersRunning: Bool) -> TimeInterval {
        otherWritersRunning ? recoveryQuietPeriod : 0
    }

    /// Marks runs left `inProgress` (the process died mid-cleanup) as finished and returns their ids.
    /// Their entries are exactly the items that finished before the interruption. A run whose file
    /// changed within `quietFor` seconds of `now` is left alone: something may still be writing it.
    public static func recoverInterrupted(
        journal: RunJournal, quietFor: TimeInterval = recoveryQuietPeriod, now: Date = Date()
    ) throws -> [UUID] {
        var ids: [UUID] = []
        for var run in try journal.all() where run.inProgress {
            if let modified = journal.modificationDate(of: run.id), now.timeIntervalSince(modified) < quietFor {
                continue
            }
            run.inProgress = false
            try journal.save(run)
            ids.append(run.id)
        }
        return ids
    }

    /// `recoverInterrupted` on the file-work queue, for callers on the main actor.
    public static func recoverInterruptedInBackground(
        journal: RunJournal, quietFor: TimeInterval = recoveryQuietPeriod
    ) async throws -> [UUID] {
        try await FileWork.run { try recoverInterrupted(journal: journal, quietFor: quietFor) }
    }

    /// `recoverInterrupted` on the file-work queue with the quiet period chosen by
    /// `otherWritersRunning` (asked there, since listing processes is a system call).
    public static func recoverInterruptedInBackground(
        journal: RunJournal, otherWritersRunning: @escaping @Sendable () -> Bool
    ) async throws -> [UUID] {
        try await FileWork.run {
            try recoverInterrupted(
                journal: journal, quietFor: recoveryQuietPeriod(otherWritersRunning: otherWritersRunning()))
        }
    }

    /// Measures and moves one item, without journaling. Callers that need to decide between items
    /// (the uninstaller moves the app first) use this and then `finish` once.
    func attempt(_ url: URL, allowedRoots: [URL]) -> JournalEntry {
        let bytes = sizer.measure(url).bytes
        let outcome = mover.moveToTrash(url, allowedRoots: allowedRoots)
        var entry = JournalEntry(originalPath: url.path(percentEncoded: false), bytes: bytes, outcome: outcome)
        // Who landed in the Trash, so a later restore can tell it from another item with the same name.
        if case .movedToTrash(let trashed) = outcome {
            entry.trashedIdentity = TrashedIdentity.of(path: trashed)
        }
        return entry
    }

    /// Journals and logs a run that changed after it was finished (an uninstall's password step):
    /// `restorable` is recomputed, the journal file replaced, and the log gets the run's header again,
    /// the entries that changed and the new totals. A journal or log failure is appended as a failed
    /// `<history>` / `<log>` entry, as `finish` does.
    func update(_ record: RunRecord, changed: [JournalEntry]) -> RunRecord {
        var record = record
        record.restorable = record.entries.contains { if case .movedToTrash = $0.outcome { !$0.restored } else { false } }
        var journalSaved = true
        do { try journal.save(record) } catch {
            journalSaved = false
            record.entries.append(Self.failure("<history>", error))
        }
        do {
            try logger.writeHeader(record)
            try logger.append(changed, to: record)
            try logger.writeTotals(record)
        } catch {
            record.entries.append(Self.failure("<log>", error))
            if journalSaved {
                do { try journal.save(record) } catch {
                    record.entries.append(Self.failure("<history>", error))
                }
            }
        }
        return record
    }

    /// Journals and logs a finished run (one record per run).
    func finish(_ entries: [JournalEntry], kind: RunKind, startedAt: Date) -> RunRecord {
        var record = RunRecord(
            startedAt: startedAt, kind: kind, entries: entries,
            restorable: entries.contains { if case .movedToTrash = $0.outcome { true } else { false } })

        var journalSaved = true
        do { try journal.save(record) } catch {
            journalSaved = false
            record.entries.append(Self.failure("<history>", error))
        }
        do { try logger.write(record) } catch {
            record.entries.append(Self.failure("<log>", error))
            if journalSaved {
                do { try journal.save(record) } catch {
                    record.entries.append(Self.failure("<history>", error))
                }
            }
        }
        return record
    }

    private static func failure(_ marker: String, _ error: Error) -> JournalEntry {
        JournalEntry(originalPath: marker, bytes: 0, outcome: .failed(reason: error.localizedDescription))
    }
}
