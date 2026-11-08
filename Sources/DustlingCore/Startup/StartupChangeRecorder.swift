import Foundation

/// Toggles a startup item through `StartupItemScanner` and records the change in History and the log,
/// like every other action. A startup change is never restorable from the Trash; it is undone by
/// toggling the item back.
public struct StartupChangeRecorder: Sendable {
    private let scanner: StartupItemScanner
    private let journal: RunJournal
    private let logger: RunLogger

    public init(scanner: StartupItemScanner, journal: RunJournal, logger: RunLogger) {
        self.scanner = scanner
        self.journal = journal
        self.logger = logger
    }

    /// Runs the change and returns the saved record. A journal or log failure is recorded once, as a
    /// failed `<history>` / `<log>` entry (the same pattern as `CleanupRunner`).
    public func setEnabled(_ item: StartupItem, _ enabled: Bool) -> RunRecord {
        var record = RunRecord(startedAt: Date(), kind: .startupChange, entries: [], restorable: false)
        var historyFailed = false
        var logFailed = false

        func save() {
            do { try journal.save(record) } catch {
                if !historyFailed {
                    historyFailed = true
                    record.entries.append(Self.failure("<history>", error))
                }
            }
        }
        func logFailure(_ error: Error) {
            logFailed = true
            record.entries.append(Self.failure("<log>", error))
        }

        // The change entry comes first; a header failure is recorded right after it.
        var headerError: Error?
        do { try logger.writeHeader(record) } catch { headerError = error; logFailed = true }

        let outcome = scanner.setEnabled(item, enabled)
        let entry = JournalEntry(
            originalPath: item.plistURL?.path(percentEncoded: false) ?? item.label, bytes: 0, outcome: outcome)
        record.entries.append(entry)
        if let headerError { record.entries.append(Self.failure("<log>", headerError)) }
        if !logFailed {
            do { try logger.append(entry, to: record) } catch { logFailure(error) }
        }
        if !logFailed {
            do { try logger.writeTotals(record) } catch { logFailure(error) }
        }
        save()
        // A history failure found by this save is part of the record but could not be journaled; if the
        // log still works, make sure it shows up there too.
        if historyFailed, !logFailed, let last = record.entries.last(where: { $0.originalPath == "<history>" }) {
            do { try logger.append(last, to: record) } catch { logFailure(error); save() }
        }
        return record
    }

    private static func failure(_ marker: String, _ error: Error) -> JournalEntry {
        JournalEntry(originalPath: marker, bytes: 0, outcome: .failed(reason: error.localizedDescription))
    }
}
