import Foundation

/// Appends a human-readable account of each run to `dustling-YYYY-MM-DD.log` (local date).
public struct RunLogger: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func write(_ run: RunRecord) throws {
        try append(Self.text(for: run), on: run.startedAt)
    }

    /// Incremental logging: header, then one line per finished item, then the totals line.
    /// Together they produce exactly what `write` does.
    public func writeHeader(_ run: RunRecord) throws {
        try append(Self.headerLine(run) + "\n", on: run.startedAt)
    }

    public func append(_ entry: JournalEntry, to run: RunRecord) throws {
        try append(Self.entryLine(entry) + "\n", on: run.startedAt)
    }

    public func writeTotals(_ run: RunRecord) throws {
        try append(Self.totalsLine(run) + "\n", on: run.startedAt)
    }

    private func append(_ text: String, on date: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "dustling-\(Self.dayStamp(date)).log")
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try Data().write(to: file)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func headerLine(_ run: RunRecord) -> String {
        "\(ISO8601DateFormatter().string(from: run.startedAt)) run=\(run.id.uuidString) kind=\(kindLabel(run.kind))"
    }

    private static func entryLine(_ entry: JournalEntry) -> String {
        var line = "  \(entry.outcome.label)  \(bytesLabel(entry.bytes))  \(entry.originalPath)"
        if case .movedToTrash(let trashed) = entry.outcome { line += " -> \(trashed)" }
        return line
    }

    private static func totalsLine(_ run: RunRecord) -> String {
        "  total: moved \(bytesLabel(run.bytesMovedToTrash)) to Trash, \(run.failedCount) failed, "
            + "\(run.needsAdminCount) need admin, \(run.skippedCount) skipped"
    }

    static func text(for run: RunRecord) -> String {
        ([headerLine(run)] + run.entries.map(entryLine) + [totalsLine(run)]).joined(separator: "\n") + "\n"
    }

    private static func bytesLabel(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private static func kindLabel(_ kind: RunKind) -> String {
        switch kind {
        case .junkClean: "junkClean"
        case .uninstall(let appName): "uninstall(\(appName))"
        case .emptyTrash: "emptyTrash"
        case .startupChange: "startupChange"
        }
    }

    private static func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
