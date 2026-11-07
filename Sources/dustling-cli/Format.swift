import DustlingCore
import Foundation

/// English-only output helpers. Kept free of I/O decisions so they stay trivially testable.
enum Format {
    /// English on any system locale.
    static func bytes(_ count: UInt64) -> String {
        bytes(Int64(clamping: count))
    }

    /// ByteCountFormatter has no locale setting (it follows the system language, so a Turkish Mac
    /// would print "MB" with a comma), so this mirrors its `.file` style: decimal units, English.
    static func bytes(_ count: Int64) -> String {
        let value = Double(max(0, count))
        let units: [(String, Int)] = [("KB", 0), ("MB", 1), ("GB", 2), ("TB", 2), ("PB", 2)]
        if value < 1000 { return count == 1 ? "1 byte" : "\(max(0, count)) bytes" }
        var scaled = value / 1000
        var index = 0
        while scaled >= 1000 && index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        return String(format: "%.\(units[index].1)f %@", scaled, units[index].0)
    }

    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) " + (count == 1 ? singular : (plural ?? singular + "s"))
    }

    /// Plain-words description of a scan problem.
    static func issue(_ issue: ScanIssue) -> String {
        switch issue {
        case .missingFullDiskAccess(let url):
            "  ! Couldn't scan \(path(url)): needs Full Disk Access "
                + "(System Settings > Privacy & Security > Full Disk Access)"
        case .unreadable(let url):
            "  ! Couldn't read \(path(url))"
        case .commandFailed(let command, let reason):
            "  ! \(command) failed: \(reason)"
        }
    }

    /// Path without the trailing slash directory URLs carry.
    static func path(_ url: URL) -> String {
        let text = url.path(percentEncoded: false)
        return text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// Prints issues, collapsing long runs (a missing Full Disk Access grant produces one per
    /// container) into the first few plus a count, so the output stays readable but nothing is hidden.
    static func printIssues(_ issues: [ScanIssue], limit: Int = 4) {
        for item in issues.prefix(limit) { print(issue(item)) }
        if issues.count > limit {
            print("  ! ...and \(issues.count - limit) more like these (\(issues.count) in total)")
        }
    }

    static func printWarning(_ text: String) {
        print("  ! \(text)")
    }

    static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func tag(for selection: Selection) -> String {
        switch selection {
        case .preselected: ""
        case .review: " [review]"
        case .emptyTrashOnly: " [trash]"
        }
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func kind(_ kind: RunKind) -> String {
        switch kind {
        case .junkClean: "junk clean"
        case .uninstall(let name): "uninstall \(name)"
        case .emptyTrash: "empty trash"
        case .startupChange: "startup change"
        }
    }

    /// True when the outcome should make the command exit with code 2.
    static func isProblem(_ outcome: DeletionOutcome) -> Bool {
        switch outcome {
        case .failed, .needsAdmin: true
        default: false
        }
    }

    static func printEntries(_ record: RunRecord) {
        for entry in record.entries {
            let size = entry.bytes > 0 ? " (\(bytes(entry.bytes)))" : ""
            print("  \(entry.originalPath)\(size): \(entry.outcome.label)")
        }
    }

    /// Prints the totals line for a record and returns the exit code (2 on any failed or needs-admin entry).
    static func printTotals(_ record: RunRecord) -> Int32 {
        let moved = record.entries.filter { if case .movedToTrash = $0.outcome { true } else { false } }.count
        let deleted = record.entries.filter { $0.outcome == .deleted }.count
        var parts: [String] = []
        if moved > 0 { parts.append("\(moved) moved to Trash (\(bytes(record.bytesMovedToTrash)))") }
        if deleted > 0 {
            let freed = record.entries.reduce(UInt64(0)) { $0 + ($1.outcome == .deleted ? $1.bytes : 0) }
            parts.append("\(deleted) deleted (\(bytes(freed)))")
        }
        if record.skippedCount > 0 { parts.append("\(record.skippedCount) skipped") }
        if record.failedCount > 0 { parts.append("\(record.failedCount) failed") }
        if record.needsAdminCount > 0 { parts.append("\(record.needsAdminCount) need admin") }
        print(parts.isEmpty ? "Nothing was changed." : "Done: " + parts.joined(separator: ", ") + ".")
        return record.entries.contains { isProblem($0.outcome) } ? 2 : 0
    }

    /// Reads a y/N answer. Anything but y/Y/yes declines. Without a TTY and without `--yes`, declines.
    static func confirm(_ prompt: String, assumeYes: Bool) -> Bool {
        if assumeYes { print("\(prompt) y (--yes)"); return true }
        guard isatty(STDIN_FILENO) != 0 else {
            print(prompt)
            print("Not running in a terminal and --yes was not given, so nothing was done.")
            return false
        }
        print(prompt, terminator: " ")
        guard let line = readLine() else { return false }
        return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
