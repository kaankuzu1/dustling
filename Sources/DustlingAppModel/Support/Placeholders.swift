import DustlingCore
import Foundation

/// Stand-in rows for the loading skeletons. The screens draw these with their real row views in
/// placeholder mode, so a skeleton row has exactly the layout of the row that replaces it; only the
/// lengths of these strings show (as the widths of the placeholder blocks), never the text itself.
/// They are made up and name nothing on this Mac.
public enum Placeholder {
    /// Varies a placeholder line's length from row to row, like the mockups' skeletons
    /// (`42 + (i * 17) % 30` percent and so on): `base` plus 0 to `spread` more characters.
    public static func text(_ index: Int, base: Int, spread: Int, step: Int = 7) -> String {
        let count = base + (spread > 0 ? (index * step) % (spread + 1) : 0)
        // Words of five, so a line that has to wrap or truncate does so like real text.
        return String((0..<count).map { $0 % 6 == 5 ? " " : "x" })
    }

    /// The same id for the same placeholder row every time, so redraws keep the row's identity.
    public static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", max(0, index)))!
    }
}

extension StartupRow {
    /// A launch agent row of made-up text, for the loading skeleton.
    public static func placeholder(_ index: Int) -> StartupRow {
        let label = "com.example." + Placeholder.text(index, base: 14, spread: 14, step: 5)
            .replacingOccurrences(of: " ", with: ".")
        return StartupRow(
            item: StartupItem(
                label: label, scope: .userAgent, plistURL: nil, program: nil, ownerAppName: nil, isEnabled: true,
                managedInSystemSettingsOnly: false),
            chip: nil, canToggle: true, showsSystemSettingsLink: false, isOrphaned: false,
            name: Placeholder.text(index, base: 10, spread: 10), kindName: "Launch agent",
            owner: Placeholder.text(index, base: 8, spread: 6, step: 3), ownerAppURL: nil, badge: nil)
    }
}

extension HistoryScreen.RunLine {
    /// A run of made-up text, for the loading skeleton.
    public static func placeholder(_ index: Int) -> HistoryScreen.RunLine {
        HistoryScreen.RunLine(
            id: Placeholder.id(index), tool: .junkScan, title: Placeholder.text(index, base: 18, spread: 14),
            when: Placeholder.text(index, base: 12, spread: 4, step: 3),
            caption: Placeholder.text(index, base: 22, spread: 16, step: 11), chip: nil, size: "00.00 GB",
            action: nil, dimmed: false)
    }
}

extension HistoryScreen.LogRow {
    /// A log line of made-up text, for the loading skeleton.
    public static func placeholder(_ index: Int) -> HistoryScreen.LogRow {
        HistoryScreen.LogRow(
            id: index, result: "moved", tone: .done, path: Placeholder.text(index, base: 40, spread: 30, step: 13),
            note: "0.00 GB")
    }
}

extension HistoryItem {
    /// An item of made-up text, for the loading skeleton.
    public static func placeholder(_ index: Int) -> HistoryItem {
        let path = "/" + Placeholder.text(index, base: 36, spread: 30, step: 13).replacingOccurrences(of: " ", with: "/")
        return HistoryItem(
            runID: Placeholder.id(index), runTitle: "Junk scan", runDate: .distantPast, runKind: .junkClean, path: path,
            bytes: 1_000_000_000, status: "Moved to the Trash", restorable: false,
            entry: JournalEntry(originalPath: path, bytes: 1_000_000_000, outcome: .movedToTrash(trashedPath: path)))
    }
}

extension AppRow {
    /// An app of made-up text, for the loading skeleton. Its bundle doesn't exist and is never read.
    public static func placeholder(_ index: Int) -> AppRow {
        let name = Placeholder.text(index, base: 9, spread: 10)
        let app = InstalledApp(
            url: URL(filePath: "/placeholder-\(index).app", directoryHint: .isDirectory), displayName: name,
            bundleID: nil, teamID: nil, executableName: nil, steamAppID: nil, bytes: 1_000_000_000,
            lastUsed: Date(timeIntervalSinceNow: -Double(2 + index % 5) * 7 * 86_400))
        return AppRow(app: app, isCounting: false, leftoverCount: 3, totalBytes: 1_000_000_000, label: nil, warning: nil)
    }
}
