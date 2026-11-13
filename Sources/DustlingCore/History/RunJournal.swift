import Foundation

public enum RunJournalError: Error, Equatable, Sendable {
    case runNotFound(UUID)
    /// The History directory exists but could not be listed.
    case historyUnreadable(URL, underlying: Error)
    /// Saving the journal failed mid-restore; `outcomes` are the moves already done (and not journaled past the failure).
    case saveFailed(outcomes: [RestoreOutcome], underlying: Error)
    /// Nothing in the run can be put back: every item was restored already or is no longer in the Trash.
    case notRestorable(UUID)

    public static func == (lhs: RunJournalError, rhs: RunJournalError) -> Bool {
        switch (lhs, rhs) {
        case (.runNotFound(let a), .runNotFound(let b)): a == b
        case (.historyUnreadable(let a, _), .historyUnreadable(let b, _)): a == b
        case (.saveFailed(let a, _), .saveFailed(let b, _)): a == b
        case (.notRestorable(let a), .notRestorable(let b)): a == b
        default: false
        }
    }
}

extension RunJournalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .runNotFound: "This run isn't in History any more."
        case .historyUnreadable(let url, _): "Dustling couldn't read its History folder (\(url.path(percentEncoded: false)))."
        case .saveFailed: "Some items came back, but Dustling couldn't update History."
        case .notRestorable: "Nothing in this run can be put back. It was put back already or is no longer in the Trash."
        }
    }
}

/// Durable, one-file-per-run record of what a cleanup did, plus the undo (`restore`).
public struct RunJournal: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// ISO 8601 with milliseconds: runs started within the same second (one per app in a multi-app
    /// uninstall) keep their order. Files written in whole seconds still read.
    private static let preciseDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondDate = Date.ISO8601FormatStyle()

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(preciseDate))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? preciseDate.parse(text) { return date }
            if let date = try? wholeSecondDate.parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return d
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    public func save(_ run: RunRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(run)
        try data.write(to: fileURL(run.id), options: .atomic)
    }

    /// When the run's file was last written, or nil if it can't be read.
    public func modificationDate(of id: UUID) -> Date? {
        (try? fileURL(id).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// A missing directory means no runs yet; any other listing error is surfaced.
    private func jsonFiles() throws -> [URL] {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
            return files.filter { $0.pathExtension == "json" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            throw RunJournalError.historyUnreadable(directory, underlying: error)
        }
    }

    /// Every readable run, newest first. Files that fail to decode are listed by `unreadableRecords()`.
    public func all() throws -> [RunRecord] {
        let decoder = Self.makeDecoder()
        var runs: [RunRecord] = []
        for url in try jsonFiles() {
            if let data = try? Data(contentsOf: url), let run = try? decoder.decode(RunRecord.self, from: data) {
                runs.append(run)
            }
        }
        return runs.sorted { $0.startedAt > $1.startedAt }
    }

    /// The run that started last, reading as few files as possible: files newest-written first, and
    /// it stops at the first file last written before the best run so far started (a run is saved
    /// after it starts, so nothing older can have started later). Unreadable files are skipped.
    public func newest() throws -> RunRecord? {
        let decoder = Self.makeDecoder()
        let dated = try jsonFiles().map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (url, date ?? .distantFuture)
        }.sorted { $0.1 > $1.1 }
        var best: RunRecord?
        for (url, written) in dated {
            if let best, written < best.startedAt { break }
            guard let data = try? Data(contentsOf: url), let run = try? decoder.decode(RunRecord.self, from: data)
            else { continue }
            if best.map({ run.startedAt > $0.startedAt }) ?? true { best = run }
        }
        return best
    }

    /// Journal files that could not be read or decoded (so the UI can say so instead of hiding them).
    public func unreadableRecords() -> [URL] {
        let decoder = Self.makeDecoder()
        return ((try? jsonFiles()) ?? []).filter { url in
            guard let data = try? Data(contentsOf: url) else { return true }
            return (try? decoder.decode(RunRecord.self, from: data)) == nil
        }.sorted { $0.path < $1.path }
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// What is at an entry's trashed path now.
    private enum TrashedState { case present, missing, replaced }

    private static func trashedState(_ entry: JournalEntry, trashed: String) -> TrashedState {
        guard let now = TrashedIdentity.of(path: trashed) else { return .missing }
        guard let recorded = entry.trashedIdentity else { return .present }   // older record: no identity
        return recorded.isSameItem(as: now) ? .present : .replaced
    }

    /// True when the entry's own item is still in the Trash and can be put back.
    public static func isRestorable(_ entry: JournalEntry) -> Bool {
        guard !entry.restored, !entry.gone, case .movedToTrash(let trashed) = entry.outcome else { return false }
        return trashedState(entry, trashed: trashed) == .present
    }

    private static func hasRestorableEntries(_ run: RunRecord) -> Bool {
        run.entries.contains { isRestorable($0) }
    }

    /// Marks entries whose trashed path now holds a different item as gone for good, and updates
    /// `restorable`. Returns true when the run changed.
    private static func refresh(_ run: inout RunRecord) -> Bool {
        var changed = false
        for index in run.entries.indices {
            let entry = run.entries[index]
            guard !entry.restored, !entry.gone, case .movedToTrash(let trashed) = entry.outcome else { continue }
            if trashedState(entry, trashed: trashed) == .replaced {
                run.entries[index].gone = true
                changed = true
            }
        }
        let restorable = hasRestorableEntries(run)
        if restorable != run.restorable {
            run.restorable = restorable
            changed = true
        }
        return changed
    }

    /// Why moving an item out of the Trash failed, in plain words. macOS refuses to let an app without
    /// Full Disk Access take anything out of the Trash, and Foundation's message then blames the
    /// destination folder; say what really happened instead.
    public static func restoreFailureReason(
        _ error: Error, trashedPath: String, destinationWritable: Bool = true, home: String = NSHomeDirectory()
    ) -> String {
        // A destination that really can't be written to keeps Foundation's own message.
        guard destinationWritable, isPermissionError(error) else { return error.localizedDescription }
        let folder = URL(fileURLWithPath: trashedPath).deletingLastPathComponent().path
        let homeTrash = URL(fileURLWithPath: home).appendingPathComponent(".Trash").path
        let shown = folder == homeTrash ? "~/.Trash" : folder
        return "Dustling can't take it out of the Trash (\(shown)) without Full Disk Access"
    }

    /// Why an item stayed in the Trash when the password box was closed.
    public static let putBackNeedsPasswordReason = "Put back needs your password"

    /// Added to the reason when the password can't put an item back because its record is older
    /// than Put back with the password (it has no owner).
    public static let putBackInFinderNote = "Use Put Back in Finder."

    /// `reason`, then `note` as its own sentence.
    static func withNote(_ reason: String, _ note: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return note }
        return trimmed + (trimmed.hasSuffix(".") ? " " : ". ") + note
    }

    /// Whether only the password can put the item back: the move failed for lack of permission and
    /// the destination folder is a real folder (lstat: not a link, which planning would refuse) that
    /// isn't writable, or the item is a folder Dustling's user can't write (moving it to another
    /// folder changes its `..`).
    private static func needsPassword(_ error: Error, trashed: String, folder: URL, folderWritable: Bool) -> Bool {
        guard isPermissionError(error) else { return false }
        var info = stat()
        let folderPath = AdminPath.trimmingTrailingSlashes(folder.path(percentEncoded: false))
        guard lstat(folderPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        if !folderWritable { return true }
        let item = AdminPath.trimmingTrailingSlashes(trashed)
        guard lstat(item, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return access(item, W_OK) != 0
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// Moves trashed entries back. Never overwrites: an occupied original path is a `.conflict`. Only
    /// the item that was trashed is ever moved: if something else now sits at its Trash path, the
    /// entry is `.missingFromTrash` and permanently gone. Throws `.notRestorable` when nothing in the
    /// run can be put back.
    ///
    /// With `admin` (pass one only when Dustling has Full Disk Access), an entry whose move back
    /// failed for lack of permission into a folder that exists but isn't writable, or that is a
    /// folder the user can't write, goes back with the Mac password: all such entries in one script
    /// (`AdminMover.restorePrompt`), each only if the item in the Trash is still the recorded one,
    /// owner included. Put back: `.restored`. The password box closed: `.failed` with
    /// `putBackNeedsPasswordReason`. The name taken meanwhile: `.conflict`; the item gone:
    /// `.missingFromTrash`; otherwise `.failed` with the script's reason. History files are plain
    /// files the user (and so any program running as the user) can write, so only an entry shaped
    /// like what Dustling itself moves with the password is sent (`PasswordPutBack`: directly out of
    /// a Trash, directly into a folder Dustling moves from with the password for the run's kind,
    /// reached without links); any other, and one recorded without an owner (older records), isn't
    /// sent: it fails with the move's reason and `putBackInFinderNote`. One whose folders Dustling
    /// can't open, or whose destination folder is missing or a link, fails with the move's reason
    /// and is never sent.
    /// The journal is saved once after the password step.
    public func restore(runID: UUID, paths: Set<String>? = nil, admin: AdminMover? = nil) throws -> [RestoreOutcome] {
        guard var run = try all().first(where: { $0.id == runID }) else {
            throw RunJournalError.runNotFound(runID)
        }
        if Self.refresh(&run) {
            do { try save(run) } catch { throw RunJournalError.saveFailed(outcomes: [], underlying: error) }
        }
        guard run.restorable else { throw RunJournalError.notRestorable(runID) }

        let fm = FileManager.default
        var results: [RestoreOutcome] = []
        var unsaved = false
        /// Entries for the password step: their entry, their slot in `results`, and the step.
        var withPassword: [(entry: Int, result: Int, step: AdminStep)] = []
        for index in run.entries.indices {
            let entry = run.entries[index]
            guard !entry.restored, case .movedToTrash(let trashed) = entry.outcome else { continue }
            if let paths, !paths.contains(entry.originalPath) { continue }
            if entry.gone {
                results.append(.missingFromTrash(entry.originalPath))
                continue
            }
            let state = Self.trashedState(entry, trashed: trashed)
            if state == .replaced {
                run.entries[index].gone = true
                unsaved = true
                results.append(.missingFromTrash(entry.originalPath))
                continue
            }
            if Self.exists(entry.originalPath) {
                results.append(.conflict(entry.originalPath))
                continue
            }
            if state == .missing {
                results.append(.missingFromTrash(entry.originalPath))
                continue
            }
            let original = URL(fileURLWithPath: entry.originalPath)
            do {
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: URL(fileURLWithPath: trashed), to: original)
            } catch {
                let folder = original.deletingLastPathComponent()
                let folderWritable = fm.isWritableFile(atPath: folder.path)
                if let admin, Self.needsPassword(error, trashed: trashed, folder: folder, folderWritable: folderWritable) {
                    // Not Full Disk Access (it's on when there is `admin`): the folder or the item itself.
                    let reason = Self.restoreFailureReason(error, trashedPath: trashed, destinationWritable: false)
                    // The run comes from a file the user can write: only a Put back shaped like what
                    // Dustling moves with the password gets the password (`PasswordPutBack`).
                    if let expected = entry.trashedIdentity?.itemIdentity,
                       let target = PasswordPutBack.target(
                           trashed: trashed, original: entry.originalPath, recordedOwner: expected.owner,
                           kind: run.kind, environment: admin.environment) {
                        let step = AdminStep(
                            op: .move(from: target.from, to: target.to, bootOutDaemon: false),
                            expectedSource: expected, expectedFolder: target.folder)
                        withPassword.append((index, results.count, step))
                        results.append(.failed(entry.originalPath, reason: reason))   // until the password step
                    } else {
                        results.append(.failed(entry.originalPath, reason: Self.withNote(reason, Self.putBackInFinderNote)))
                    }
                    continue
                }
                results.append(.failed(entry.originalPath, reason: Self.restoreFailureReason(
                    error, trashedPath: trashed, destinationWritable: folderWritable)))
                continue
            }
            run.entries[index].restored = true
            results.append(.restored(entry.originalPath))
            // Journal after every move so the record always matches disk; stop if that fails.
            run.restorable = Self.hasRestorableEntries(run)
            do { try save(run) } catch {
                throw RunJournalError.saveFailed(outcomes: results, underlying: error)
            }
            unsaved = false
        }
        if let admin, !withPassword.isEmpty {
            let outcomes = admin.performOpenable(withPassword.map(\.step), prompt: AdminMover.restorePrompt)
            for (item, outcome) in zip(withPassword, outcomes) {
                let path = run.entries[item.entry].originalPath
                switch outcome {
                case nil:
                    break   // Dustling can't open a folder the move needs: the move's own failure stands.
                case .done?:
                    run.entries[item.entry].restored = true
                    results[item.result] = .restored(path)
                    unsaved = true
                case .cancelled?:
                    results[item.result] = .failed(path, reason: Self.putBackNeedsPasswordReason)
                case .notDone(let reason)?:
                    switch reason {
                    case AdminScript.existsReason: results[item.result] = .conflict(path)
                    case AdminScript.goneReason: results[item.result] = .missingFromTrash(path)
                    default: results[item.result] = .failed(path, reason: reason)
                    }
                }
            }
        }
        let restorable = Self.hasRestorableEntries(run)
        if restorable != run.restorable || unsaved {
            run.restorable = restorable
            do { try save(run) } catch {
                throw RunJournalError.saveFailed(outcomes: results, underlying: error)
            }
        }
        return results
    }

    /// Clears `restorable` on runs whose trashed items are all gone (Trash emptied, or the name reused
    /// by another item) or restored.
    public func refreshRestorability() throws {
        for var run in try all() where Self.refresh(&run) {
            try save(run)
        }
    }
}
