import Foundation

/// The single path every cleanup and uninstall goes through: measure, trash, record, journal, log.
public struct CleanupRunner: Sendable {
    private let mover: TrashMover
    private let journal: RunJournal
    private let logger: RunLogger
    private let sizer: DirectorySizer

    public init(mover: TrashMover, journal: RunJournal, logger: RunLogger, sizer: DirectorySizer) {
        self.mover = mover
        self.journal = journal
        self.logger = logger
        self.sizer = sizer
    }

    /// `extraEntries` (e.g. launch-agent unload failures) are appended after the runner's own entries.
    /// Journal/log failures are appended to the returned record as `<history>` / `<log>` entries.
    public func run(
        _ urls: [URL],
        kind: RunKind,
        allowedRoots: [URL],
        extraEntries: [JournalEntry] = [],
        onItem: @Sendable (URL, DeletionOutcome) -> Void
    ) async -> RunRecord {
        let startedAt = Date()
        var entries: [JournalEntry] = []
        for url in urls {
            let entry = attempt(url, allowedRoots: allowedRoots)
            entries.append(entry)
            onItem(url, entry.outcome)
        }
        return finish(entries + extraEntries, kind: kind, startedAt: startedAt)
    }

    /// Measures and moves one item, without journaling. Callers that need to decide between items
    /// (the uninstaller moves the app first) use this and then `finish` once.
    func attempt(_ url: URL, allowedRoots: [URL]) -> JournalEntry {
        let bytes = sizer.measure(url).bytes
        let outcome = mover.moveToTrash(url, allowedRoots: allowedRoots)
        return JournalEntry(originalPath: url.path(percentEncoded: false), bytes: bytes, outcome: outcome)
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
