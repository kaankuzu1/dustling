import Foundation

/// Appends a human-readable account of each run to `dustling-YYYY-MM-DD.log` (local date).
public struct RunLogger: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func write(_ run: RunRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "dustling-\(Self.dayStamp(run.startedAt)).log")
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try Data().write(to: file)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(Self.text(for: run).utf8))
    }

    static func text(for run: RunRecord) -> String {
        var lines = ["\(ISO8601DateFormatter().string(from: run.startedAt)) run=\(run.id.uuidString) kind=\(kindLabel(run.kind))"]
        for entry in run.entries {
            var line = "  \(entry.outcome.label)  \(bytesLabel(entry.bytes))  \(entry.originalPath)"
            if case .movedToTrash(let trashed) = entry.outcome { line += " -> \(trashed)" }
            lines.append(line)
        }
        lines.append(
            "  total: moved \(bytesLabel(run.bytesMovedToTrash)) to Trash, \(run.failedCount) failed, "
                + "\(run.needsAdminCount) need admin, \(run.skippedCount) skipped")
        return lines.joined(separator: "\n") + "\n"
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
