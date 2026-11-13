import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

struct HistoryScreenTests {
    private static let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.utc
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// 8 Nov 2026, 20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_168_000)

    private func at(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 11, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func moved(_ path: String, _ bytes: UInt64, restored: Bool = false) -> JournalEntry {
        JournalEntry(originalPath: path, bytes: bytes, outcome: .movedToTrash(trashedPath: "/t/" + path), restored: restored)
    }

    private func row(
        _ kind: RunKind, _ date: Date, _ entries: [JournalEntry], restorable: Bool = false
    ) -> RunRow {
        let record = RunRecord(startedAt: date, kind: kind, entries: entries, restorable: restorable)
        return RunRow(
            record: record, title: "", chip: nil, restorable: restorable, inProgress: false,
            itemCount: entries.filter { !$0.originalPath.hasPrefix("<") }.count, bytes: record.bytesMovedToTrash)
    }

    private func context(lastEmpty: Date? = nil, trash: Bool = true) -> HistoryScreen.Context {
        HistoryScreen.Context(
            lastEmptyTrash: lastEmpty, canTakeOutOfTrash: trash,
            environment: SystemEnvironment(
                home: URL(filePath: "/Users/k"), applicationDirectories: [], systemLibrary: URL(filePath: "/Library"),
                volumesDirectory: URL(filePath: "/Volumes"), userID: 501),
            now: now, calendar: calendar, locale: locale)
    }

    // MARK: dates

    @Test func whenReadsTodayYesterdayOrTheDate() {
        let c = context()
        #expect(HistoryScreen.when(at(8, 19, 4), c) == "Today, 19:04")
        #expect(HistoryScreen.when(at(7, 21, 12), c) == "Yesterday, 21:12")
        #expect(HistoryScreen.when(at(4, 10, 22), c) == "4 Nov, 10:22")
        #expect(HistoryScreen.when(at(28, 16, 5, month: 10, year: 2025), c) == "28 Oct 2025, 16:05")
    }

    // MARK: runs

    @Test func runLinesFollowTheDesign() {
        let c = context()
        let junk = HistoryScreen.runLine(row(.junkClean, at(8, 19, 4), [
            moved("/a", 2_000_000_000), moved("/b", 1_000_000_000),
            JournalEntry(originalPath: "/c", bytes: 5, outcome: .skipped(reason: "in use by Mail")),
        ], restorable: true), c)
        #expect(junk.tool == .junkScan)
        #expect(junk.title == "Junk scan")
        #expect(junk.caption == "3 items, 1 skipped")
        #expect(junk.chip == .canBeRestored)
        #expect(junk.chip?.text == "Can be restored")
        #expect(junk.when == "Today, 19:04")
        #expect(junk.size == "3 GB")
        #expect(junk.action == .restore)
        #expect(!junk.dimmed)

        let apps = HistoryScreen.runLine(row(.uninstall(appName: "Docker Desktop"), at(8, 18, 40), [
            moved("/Applications/Docker.app", 10),
            JournalEntry(originalPath: "/x", bytes: 0, outcome: .failed(reason: "busy")),
            JournalEntry(originalPath: "/y", bytes: 0, outcome: .needsAdmin),
        ], restorable: true), c)
        #expect(apps.title == "Uninstaller: Docker Desktop")
        #expect(apps.caption == "3 items, 1 failed, 1 needs your Mac password")
        let limited = HistoryScreen.runLine(row(.junkClean, at(8, 18, 40), [
            JournalEntry(originalPath: "/y", bytes: 0, outcome: .needsAdmin),
            JournalEntry(originalPath: "/z", bytes: 0, outcome: .needsAdmin),
        ]), context(trash: false))
        #expect(limited.caption == "2 items, 2 need Full Disk Access, then your Mac password")
        let daemon = HistoryScreen.runLine(row(.startupChange, at(8, 18, 40), [
            JournalEntry(originalPath: "/Library/LaunchDaemons/x.plist", bytes: 0, outcome: .needsAdmin),
        ]), c)
        #expect(daemon.caption.hasSuffix("1 needs the helper"))
    }

    @Test func startupTogglesReadTurnedOffNeverSkipped() {
        let c = context()
        let off = HistoryScreen.runLine(row(.startupChange, at(7, 21, 12), [
            JournalEntry(originalPath: "/Users/k/Library/LaunchAgents/com.zoom.updater.plist", bytes: 0,
                         outcome: .skipped(reason: "disabled")),
        ]), c)
        #expect(off.tool == .startupItems)
        #expect(off.title == "Startup items: com.zoom.updater")
        #expect(off.caption == "Turned off")
        #expect(off.chip == .turnedOff)
        #expect(off.chip?.text == "Turned off")
        #expect(off.size == nil)
        #expect(off.action == nil)
        let failed = HistoryScreen.runLine(row(.startupChange, at(7, 21, 12), [
            JournalEntry(originalPath: "/p/com.x.plist", bytes: 0, outcome: .failed(reason: "nope")),
        ]), c)
        #expect(failed.caption == "1 item, 1 failed")
        #expect(failed.chip == .failed)
        let removed = HistoryScreen.runLine(row(.startupChange, at(7, 21, 12), [moved("/p/com.logi.updater.plist", 4096)],
                                                restorable: true), c)
        #expect(removed.title == "Startup items: com.logi.updater")
        #expect(removed.chip == .canBeRestored)
    }

    @Test func emptyTrashRunsShowWhatWasDeleted() {
        let line = HistoryScreen.runLine(row(.emptyTrash, at(5, 9, 0), [
            JournalEntry(originalPath: "/t/a", bytes: 1_000_000, outcome: .deleted),
            JournalEntry(originalPath: "/t/b", bytes: 0, outcome: .failed(reason: "in use")),
        ]), context())
        #expect(line.tool == .emptyTrash)
        #expect(line.title == "Empty Trash")
        #expect(line.caption == "2 items, 1 failed")
        #expect(line.size == "1 MB")
        #expect(line.chip == nil)
        #expect(line.action == nil)
    }

    @Test func chipsForRunsThatCantBeRestored() {
        let lastEmpty = at(5, 9, 0)
        let old = HistoryScreen.runLine(row(.junkClean, at(4, 10, 22), [moved("/a", 1)]), context(lastEmpty: lastEmpty))
        #expect(old.chip == .trashEmptied)
        #expect(old.dimmed)
        #expect(old.action == nil)
        let back = HistoryScreen.runLine(row(.junkClean, at(6, 10, 0), [moved("/a", 1, restored: true)]),
                                         context(lastEmpty: lastEmpty))
        #expect(back.chip == .putBack)
        let gone = HistoryScreen.runLine(row(.junkClean, at(6, 10, 0), [moved("/a", 1)]), context(lastEmpty: lastEmpty))
        #expect(gone.chip == .notInTrash)
        #expect(gone.chip?.text == "No longer in the Trash")
        // Without Full Disk Access the Trash can't be checked or emptied from: say only what is known.
        let limited = HistoryScreen.runLine(row(.junkClean, at(6, 10, 0), [moved("/a", 1)]),
                                            context(lastEmpty: lastEmpty, trash: false))
        #expect(limited.chip == .movedToTrash)
        #expect(limited.action == .showInTrash)
        let limitedRestorable = HistoryScreen.runLine(row(.junkClean, at(6, 10, 0), [moved("/a", 1)], restorable: true),
                                                      context(trash: false))
        #expect(limitedRestorable.chip == .canBeRestored)
        #expect(limitedRestorable.action == .showInTrash)
    }

    @Test func timelinePutsTheDashedLineBelowTheLastEmptyTrash() {
        let lastEmpty = at(5, 9, 0)
        let rows = [
            row(.junkClean, at(8, 19, 4), [moved("/a", 1)], restorable: true),
            row(.emptyTrash, lastEmpty, [JournalEntry(originalPath: "/t/a", bytes: 1, outcome: .deleted)]),
            row(.emptyTrash, at(1, 9, 0), []),
            row(.junkClean, at(28, 16, 5, month: 10), [moved("/b", 1)]),
        ]
        let entries = HistoryScreen.timeline(rows, context(lastEmpty: lastEmpty))
        #expect(entries.map(\.kind) == [.run, .run, .cut, .run, .run])
        guard case .trashEmptied(let text) = entries[2] else {
            Issue.record("expected the dashed line")
            return
        }
        #expect(text == "Trash emptied on 5 Nov. Older runs can't be restored.")
        let today = HistoryScreen.timeline([row(.emptyTrash, at(8, 9, 0), [])], context(lastEmpty: at(8, 9, 0)))
        #expect(today.last?.cutText == "Trash emptied today. Older runs can't be restored.")
        #expect(HistoryScreen.timeline(rows, context()).allSatisfy { $0.kind == .run })
    }

    @Test func subtitleCountsRunsAndRestorable() {
        let rows = [
            row(.junkClean, at(8, 19, 4), [moved("/a", 1)], restorable: true),
            row(.junkClean, at(8, 10, 4), [moved("/a", 1)]),
        ]
        #expect(HistoryScreen.subtitle(rows, isLoading: false) == "2 runs, 1 can still be restored")
        #expect(HistoryScreen.subtitle([rows[1]], isLoading: false) == "1 run, none can be restored")
        #expect(HistoryScreen.subtitle([], isLoading: false) == "No runs yet")
        #expect(HistoryScreen.subtitle([], isLoading: true) == "Reading History…")
    }

    // MARK: log

    @Test func logRowsShowEveryOutcomeHonestly() {
        let record = RunRecord(startedAt: at(8, 19, 4), kind: .junkClean, entries: [
            moved("/Users/k/Library/Caches/A", 3_410_000_000),
            JournalEntry(originalPath: "/Users/k/Library/Mail/x", bytes: 0, outcome: .skipped(reason: "in use by Mail")),
            JournalEntry(originalPath: "/Library/Application Support/y", bytes: 0, outcome: .needsAdmin),
            JournalEntry(originalPath: "/Users/k/z", bytes: 0, outcome: .failed(reason: "disk exploded")),
            moved("/Users/k/back", 10, restored: true),
            JournalEntry(originalPath: "<log>", bytes: 0, outcome: .failed(reason: "disk full")),
        ], restorable: true)
        let rows = HistoryScreen.logRows(record, context())
        #expect(rows.map(\.result) == ["moved", "skipped", "needs password", "failed", "put back", "failed"])
        #expect(rows.map(\.tone) == [.done, .skipped, .skipped, .failed, .done, .failed])
        #expect(rows.map(\.path) == [
            "~/Library/Caches/A", "~/Library/Mail/x", "/Library/Application Support/y", "~/z", "~/back", "Dustling's log file",
        ])
        #expect(rows.map(\.note) == [
            "3.41 GB", "in use by Mail", "needs your Mac password", "disk exploded", "10 bytes", "disk full",
        ])
        // Without Full Disk Access the password step can't run: access comes first.
        #expect(HistoryScreen.logRows(record, context(trash: false))[2].note
            == "needs Full Disk Access, then your Mac password")
        // Switching startup items is still the cleanup helper's job.
        let startup = RunRecord(startedAt: at(8, 19, 4), kind: .startupChange, entries: [
            JournalEntry(originalPath: "/Library/LaunchDaemons/x.plist", bytes: 0, outcome: .needsAdmin),
        ], restorable: false)
        #expect(HistoryScreen.logRows(startup, context())[0].result == "needs helper")
        #expect(HistoryScreen.logRows(startup, context())[0].note == "needs the cleanup helper")
    }

    @Test func olderRunsSystemCachesAndLogsReadAsLeftAloneNeverAsNeedingThePassword() {
        // Dustling never cleans what macOS manages. A run from before that listed items in the
        // system's caches and logs as needing the password: they read as today's runs record them.
        let record = RunRecord(startedAt: at(8, 19, 4), kind: .junkClean, entries: [
            moved("/Users/k/Library/Caches/A", 10),
            JournalEntry(originalPath: "/Library/Caches/com.apple.iconservices.store", bytes: 0, outcome: .needsAdmin),
            JournalEntry(originalPath: "/Library/Logs/install.log", bytes: 0, outcome: .needsAdmin),
            JournalEntry(originalPath: "/Library/Application Support/com.vendor", bytes: 0, outcome: .needsAdmin),
        ], restorable: true)
        let rows = HistoryScreen.logRows(record, context())
        #expect(rows.map(\.result) == ["moved", "skipped", "skipped", "needs password"])
        #expect(rows[1].note == "macOS manages it, so Dustling leaves it alone")
        #expect(rows[1].tone == .skipped)
        #expect(rows[3].note == "needs your Mac password")
        #expect(HistoryScreen.logFilters(record, context()).map(\.label) == ["All 4", "Moved 1", "Skipped 3", "Failed 0"])
        let line = HistoryScreen.runLine(row(.junkClean, at(8, 19, 4), record.entries, restorable: true), context())
        #expect(line.caption == "4 items, 2 skipped, 1 needs your Mac password")
        let status = HistoryScreen.itemStatus(
            record.entries[1], kind: .junkClean, runDate: at(8, 19, 4), restorable: true, context())
        #expect(status == HistoryScreen.ItemStatus(text: "Skipped: macOS manages it, so Dustling leaves it alone", tone: .warning))
        #expect(!HistoryScreen.itemStatus(
            record.entries[1], kind: .junkClean, runDate: at(8, 19, 4), restorable: true, context(trash: false))
            .text.contains("password"))
        // Only the environment's own system Library counts.
        var elsewhere = context()
        elsewhere.environment.systemLibrary = URL(filePath: "/Volumes/Other/Library")
        #expect(HistoryScreen.logRows(record, elsewhere)[1].result == "needs password")
    }

    @Test func logRowsForStartupAndEmptyTrash() {
        let toggle = RunRecord(startedAt: at(8, 19, 4), kind: .startupChange, entries: [
            JournalEntry(originalPath: "/p/a.plist", bytes: 0, outcome: .skipped(reason: "disabled")),
        ], restorable: false)
        let row = HistoryScreen.logRows(toggle, context())[0]
        #expect(row.result == "turned off")
        #expect(row.tone == .done)
        #expect(row.note == "")
        let empty = RunRecord(startedAt: at(8, 19, 4), kind: .emptyTrash, entries: [
            JournalEntry(originalPath: "/Users/k/.Trash/a", bytes: 2_000, outcome: .deleted),
        ], restorable: false)
        #expect(HistoryScreen.logRows(empty, context()).map(\.result) == ["deleted"])
    }

    @Test func logFiltersCountByResult() {
        let record = RunRecord(startedAt: at(8, 19, 4), kind: .junkClean, entries: [
            moved("/a", 1), moved("/b", 1),
            JournalEntry(originalPath: "/c", bytes: 0, outcome: .skipped(reason: "x")),
            JournalEntry(originalPath: "/d", bytes: 0, outcome: .needsAdmin),
        ], restorable: true)
        let filters = HistoryScreen.logFilters(record, context())
        #expect(filters.map(\.label) == ["All 4", "Moved 2", "Skipped 2", "Failed 0"])
        let rows = HistoryScreen.logRows(record, context())
        #expect(rows.filter { HistoryScreen.LogFilter.skipped.includes($0) }.count == 2)
        #expect(rows.filter { HistoryScreen.LogFilter.all.includes($0) }.count == 4)
        let empty = RunRecord(startedAt: at(8, 19, 4), kind: .emptyTrash, entries: [], restorable: false)
        #expect(HistoryScreen.logFilters(empty, context()).map(\.label) == ["All 0", "Deleted 0", "Skipped 0", "Failed 0"])
        let startup = RunRecord(startedAt: at(8, 19, 4), kind: .startupChange, entries: [], restorable: false)
        #expect(HistoryScreen.logFilters(startup, context())[1].label == "Changed 0")
    }

    @Test func logTitleNamesTheRun() {
        let record = RunRecord(startedAt: at(8, 19, 4), kind: .junkClean, entries: [], restorable: false)
        #expect(HistoryScreen.logTitle(record, context()) == "Junk scan, today 19:04")
        let old = RunRecord(startedAt: at(4, 10, 22), kind: .uninstall(appName: "Zoom"), entries: [], restorable: false)
        #expect(HistoryScreen.logTitle(old, context()) == "Uninstaller: Zoom, 4 Nov 10:22")
    }

    // MARK: bug report

    @Test func bugReportIsTheRunsOwnLogLines() {
        let id = UUID()
        let other = UUID()
        let record = RunRecord(id: id, startedAt: at(8, 19, 4), kind: .startupChange, entries: [
            JournalEntry(originalPath: "/Users/k/Library/LaunchAgents/a.plist", bytes: 0, outcome: .skipped(reason: "disabled")),
        ], restorable: false)
        let totals = RunLogger.text(for: record).split(separator: "\n").last!
        let log = """
        2026-11-08T19:00:00Z run=\(other.uuidString) kind=junkClean
          moved to Trash  1 KB  /Users/k/other -> /Users/k/.Trash/other
          total: moved 1 KB to Trash, 0 failed, 0 need admin, 0 skipped
        2026-11-08T19:04:00Z run=\(id.uuidString) kind=startupChange
          skipped: disabled  Zero KB  /Users/k/Library/LaunchAgents/a.plist
        \(totals)
        2026-11-08T19:05:00Z run=\(other.uuidString) kind=emptyTrash

        """
        #expect(HistoryScreen.bugReport(logText: log, record: record, home: "/Users/k") == """
        2026-11-08T19:04:00Z run=\(id.uuidString) kind=startupChange
          skipped: disabled  Zero KB  ~/Library/LaunchAgents/a.plist
        \(totals)

        """)
    }

    @Test func bugReportSkipsLinesOfRunsWrittenInBetween() {
        let id = UUID()
        let other = UUID()
        let record = RunRecord(id: id, startedAt: at(8, 19, 4), kind: .junkClean, entries: [
            JournalEntry(originalPath: "/Users/k/a", bytes: 0, outcome: .skipped(reason: "in use")),
            JournalEntry(originalPath: "/Users/k/b", bytes: 0, outcome: .failed(reason: "nope")),
        ], restorable: false)
        let totals = RunLogger.text(for: record).split(separator: "\n").last!
        let otherTotals = "  total: moved Zero KB to Trash, 0 failed, 0 need admin, 1 skipped"
        let log = """
        2026-11-08T19:04:00Z run=\(id.uuidString) kind=junkClean
          skipped: in use  Zero KB  /Users/k/a
        2026-11-08T19:04:01Z run=\(other.uuidString) kind=startupChange
          skipped: disabled  Zero KB  /Users/k/Library/LaunchAgents/x.plist
        \(otherTotals)
          failed: nope  Zero KB  /Users/k/b
        \(totals)

        """
        #expect(HistoryScreen.bugReport(logText: log, record: record, home: "/Users/k") == """
        2026-11-08T19:04:00Z run=\(id.uuidString) kind=junkClean
          skipped: in use  Zero KB  ~/a
          failed: nope  Zero KB  ~/b
        \(totals)

        """)
        // A line missing from the log: the text comes from the record instead.
        let short = log.replacingOccurrences(of: "  failed: nope  Zero KB  /Users/k/b\n", with: "")
        #expect(HistoryScreen.bugReport(logText: short, record: record, home: "/Users/k")
            == HistoryScreen.bugReport(logText: nil, record: record, home: "/Users/k"))
    }

    @Test func bugReportFallsBackToTheRecordWhenTheLogLacksTheRun() {
        let record = RunRecord(startedAt: at(8, 19, 4), kind: .junkClean, entries: [moved("/Users/k/a", 1)], restorable: true)
        let text = HistoryScreen.bugReport(logText: nil, record: record, home: "/Users/k")
        #expect(text.hasPrefix("2026-11-08T19:04:00Z run=\(record.id.uuidString) kind=junkClean\n"))
        let size = ByteCountFormatter.string(fromByteCount: 1, countStyle: .file)
        #expect(text.split(separator: "\n")[1] == "  moved to Trash  \(size)  ~/a -> /t/~/a")
        #expect(!text.contains("/Users/k/"))
        #expect(HistoryScreen.bugReport(logText: "unrelated\n", record: record, home: "/Users/k")
            == HistoryScreen.bugReport(logText: nil, record: record, home: "/Users/k"))
    }

    // MARK: items

    @Test func itemStatusSaysWhereEachItemIs() {
        let c = context(lastEmpty: at(5, 9, 0))
        func status(_ entry: JournalEntry, _ kind: RunKind = .junkClean, date: Date? = nil, restorable: Bool = false,
                    in ctx: HistoryScreen.Context? = nil) -> HistoryScreen.ItemStatus {
            HistoryScreen.itemStatus(entry, kind: kind, runDate: date ?? at(6, 9, 0), restorable: restorable, ctx ?? c)
        }
        #expect(status(moved("/a", 1), restorable: true) == HistoryScreen.ItemStatus(text: "In the Trash", tone: .neutral))
        #expect(status(moved("/a", 1, restored: true)).text == "Put back")
        #expect(status(moved("/a", 1, restored: true)).tone == .success)
        #expect(status(moved("/a", 1), date: at(4, 9, 0)).text == "Trash emptied")
        #expect(status(moved("/a", 1)).text == "No longer in the Trash")
        #expect(status(moved("/a", 1), in: context(trash: false)).text == "Moved to Trash")
        #expect(status(JournalEntry(originalPath: "/a", bytes: 0, outcome: .skipped(reason: "in use")))
            == HistoryScreen.ItemStatus(text: "Skipped: in use", tone: .warning))
        #expect(status(JournalEntry(originalPath: "/a", bytes: 0, outcome: .failed(reason: "x"))).tone == .warning)
        #expect(status(JournalEntry(originalPath: "/a", bytes: 0, outcome: .needsAdmin)).text == "Needs your Mac password")
        #expect(status(JournalEntry(originalPath: "/a", bytes: 0, outcome: .needsAdmin), in: context(trash: false)).text
            == "Needs Full Disk Access, then your Mac password")
        #expect(status(JournalEntry(originalPath: "/a", bytes: 0, outcome: .needsAdmin), .startupChange).text
            == "Needs the cleanup helper")
        #expect(status(JournalEntry(originalPath: "/a", bytes: 0, outcome: .skipped(reason: "disabled")), .startupChange)
            == HistoryScreen.ItemStatus(text: "Turned off", tone: .neutral))
        #expect(status(JournalEntry(originalPath: "/a", bytes: 9, outcome: .deleted), .emptyTrash).text == "Deleted")
    }

    @Test func restoreSummaryNamesEveryItemThatDidntComeBack() {
        let all = HistoryScreen.restoreSummary([.restored("/a"), .restored("/b")])
        #expect(all == HistoryScreen.RestoreSummary(success: true, title: "Put back 2 items.", problems: [], restoredCount: 2))
        #expect(all.backLine == "They're back where they were.")
        #expect(HistoryScreen.restoreSummary([.restored("/a")]).backLine == "It's back where it was.")
        let mixed = HistoryScreen.restoreSummary([
            .restored("/a"), .conflict("/x/b.txt"), .missingFromTrash("/x/c"), .failed("/x/d", reason: "no room"),
        ])
        #expect(!mixed.success)
        #expect(mixed.title == "Put back 1 item. 3 didn't come back.")
        #expect(mixed.problems == [
            "b.txt: something with the same name is already there",
            "c: no longer in the Trash",
            "d: no room",
        ])
        #expect(HistoryScreen.restoreSummary([.conflict("/a")]).title == "Nothing was put back.")
    }

    @Test func runColumnNamesTheToolAndTheDay() {
        let c = context()
        #expect(HistoryScreen.runColumn(.uninstall(appName: "Docker"), at(8, 18, 40), c) == "Uninstaller, today")
        #expect(HistoryScreen.runColumn(.junkClean, at(7, 18, 40), c) == "Junk scan, yesterday")
        #expect(HistoryScreen.runColumn(.startupChange, at(4, 18, 40), c) == "Startup items, 4 Nov")
    }
}
