import Foundation

public enum RunJournalError: Error, Equatable, Sendable {
    case runNotFound(UUID)
}

/// Durable, one-file-per-run record of what a cleanup did, plus the undo (`restore`).
public struct RunJournal: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
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

    private func jsonFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    /// Every readable run, newest first. Files that fail to decode are listed by `unreadableRecords()`.
    public func all() throws -> [RunRecord] {
        let decoder = Self.makeDecoder()
        var runs: [RunRecord] = []
        for url in jsonFiles() {
            if let data = try? Data(contentsOf: url), let run = try? decoder.decode(RunRecord.self, from: data) {
                runs.append(run)
            }
        }
        return runs.sorted { $0.startedAt > $1.startedAt }
    }

    /// Journal files that could not be read or decoded (so the UI can say so instead of hiding them).
    public func unreadableRecords() -> [URL] {
        let decoder = Self.makeDecoder()
        return jsonFiles().filter { url in
            guard let data = try? Data(contentsOf: url) else { return true }
            return (try? decoder.decode(RunRecord.self, from: data)) == nil
        }.sorted { $0.path < $1.path }
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Moves trashed entries back. Never overwrites: an occupied original path is a `.conflict`.
    public func restore(runID: UUID, paths: Set<String>? = nil) throws -> [RestoreOutcome] {
        guard var run = try all().first(where: { $0.id == runID }) else {
            throw RunJournalError.runNotFound(runID)
        }
        let fm = FileManager.default
        var results: [RestoreOutcome] = []
        for index in run.entries.indices {
            let entry = run.entries[index]
            guard !entry.restored, case .movedToTrash(let trashed) = entry.outcome else { continue }
            if let paths, !paths.contains(entry.originalPath) { continue }
            if Self.exists(entry.originalPath) {
                results.append(.conflict(entry.originalPath))
                continue
            }
            if !Self.exists(trashed) {
                results.append(.missingFromTrash(entry.originalPath))
                continue
            }
            do {
                let original = URL(fileURLWithPath: entry.originalPath)
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: URL(fileURLWithPath: trashed), to: original)
                run.entries[index].restored = true
                results.append(.restored(entry.originalPath))
            } catch {
                results.append(.failed(entry.originalPath, reason: error.localizedDescription))
            }
        }
        run.restorable = Self.hasRestorableEntries(run)
        try save(run)
        return results
    }

    private static func hasRestorableEntries(_ run: RunRecord) -> Bool {
        run.entries.contains { entry in
            if !entry.restored, case .movedToTrash(let trashed) = entry.outcome { return exists(trashed) }
            return false
        }
    }

    /// Clears `restorable` on runs whose trashed items are all gone (Trash emptied) or restored.
    public func refreshRestorability() throws {
        for var run in try all() {
            let now = Self.hasRestorableEntries(run)
            if now != run.restorable {
                run.restorable = now
                try save(run)
            }
        }
    }
}
