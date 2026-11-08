import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

/// A directory URL's path ends in "/" (`/Users/k/`). Every helper that shortens the home folder to
/// `~` must still do it, so the user name never reaches the screen or a bug report.
struct HomePathTests {
    private let slashed = "/Users/k/"

    @Test func homeKeyDropsTrailingSlashes() {
        #expect(HistoryScreen.homeKey("/Users/k/") == "/Users/k")
        #expect(HistoryScreen.homeKey("/Users/k//") == "/Users/k")
        #expect(HistoryScreen.homeKey("/Users/k") == "/Users/k")
        #expect(HistoryScreen.homeKey("/") == "")
    }

    @Test func displayPathShortensWithASlashedHome() {
        #expect(HistoryScreen.displayPath("/Users/k/Library/LaunchAgents/a.plist", home: slashed) == "~/Library/LaunchAgents/a.plist")
        #expect(HistoryScreen.displayPath("/Users/k", home: slashed) == "~")
        #expect(HistoryScreen.displayPath("/Users/kate/x", home: slashed) == "/Users/kate/x")
    }

    @Test func bugReportShortensWithASlashedHome() {
        let record = RunRecord(startedAt: Date(timeIntervalSince1970: 1_800_000_000), kind: .junkClean, entries: [
            JournalEntry(originalPath: "/Users/k/Library/Caches/x", bytes: 1, outcome: .movedToTrash(trashedPath: "/Users/k/.Trash/x")),
        ], restorable: true)
        let text = HistoryScreen.bugReport(logText: nil, record: record, home: slashed)
        #expect(!text.contains("/Users/k"))
        #expect(text.contains("~/Library/Caches/x -> ~/.Trash/x"))
    }

    @Test func issueSummaryShortensWithASlashedHome() {
        let text = StartupScreen.issueSummary([.unreadable(URL(filePath: "/Users/k/Library/LaunchAgents"))], home: slashed)
        #expect(text.contains("~/Library/LaunchAgents"))
        #expect(!text.contains("/Users/k"))
    }

    @Test func otherHelpersShortenWithASlashedHome() {
        let home = URL(filePath: slashed, directoryHint: .isDirectory)
        #expect(home.path(percentEncoded: false) == slashed)
        let file = URL(filePath: "/Users/k/Library/Caches/x")
        #expect(JunkScreen.displayPath(file, home: home) == "~/Library/Caches/x")
        #expect(UninstallerScreen.path(file, home: home) == "~/Library/Caches/x")
        #expect(AppSettings.tilde("/Users/k/Projects/keep", home: home) == "~/Projects/keep")
        #expect(LastRunReview.displayPath("/Users/k/Library/Caches/x", home: home) == "~/Library/Caches/x")
        let scrubbed = DiagnosticsReport.scrub("Couldn't read /Users/k and /Users/k/Library", home: home)
        #expect(!scrubbed.contains("/Users/k"))
        #expect(!scrubbed.contains(" k "))
    }
}
