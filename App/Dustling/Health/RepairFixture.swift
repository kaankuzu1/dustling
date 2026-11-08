#if DEBUG
import DustlingAppModel
import DustlingCore
import Foundation

/// DEBUG only. The three repair cases from SCREENS-final §8 for screenshots, since this Mac can't
/// show them safely: `-DustlingRepairFixture helper|fda|results`.
/// - `helper`: the helper is "not available yet" in v1, so this is the real state; opens Diagnostics.
/// - `fda`: Full Disk Access is treated as lost (it was on, a real read is denied now), so the next
///   scan stops at the blocker sheet. The memory is in-memory only, so nothing is saved.
/// - `results`: a sample last run with 2 items in use by Mail (the mockup's numbers). Retry refuses
///   it, so the real history is never written.
extension AppModels {
    /// The sample last run the health model reads instead of the history (`results` only).
    static var sampleLastRun: RunRecord?

    func applyRepairFixtureFromLaunchArguments() {
        guard let state = UserDefaults.standard.string(forKey: "DustlingRepairFixture") else { return }
        switch state {
        case "fda":
            // In memory only: "Not now" and later probes never touch the saved value.
            accessMemory.useSample(wasGranted: true)
        case "results":
            Self.sampleLastRun = Self.sampleRun(home: homeDirectory)
            retry.refusesSampleData = true
            health.refreshLastRun()
            selection = .diagnostics
        default:
            selection = .diagnostics
        }
    }

    private static func sampleRun(home: URL) -> RunRecord {
        let mail = home.appending(path: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        func moved(_ path: String, _ bytes: UInt64) -> JournalEntry {
            JournalEntry(originalPath: path, bytes: bytes, outcome: .movedToTrash(trashedPath: "/sample"))
        }
        return RunRecord(
            startedAt: Calendar.current.date(bySettingHour: 19, minute: 4, second: 2, of: .now) ?? .now,
            kind: .junkClean,
            entries: [
                moved(home.appending(path: "Library/Developer/Xcode/DerivedData/Dustling-gbhyqz").path, 3_410_000_000),
                moved(home.appending(path: "Library/Caches/Homebrew/downloads").path, 2_060_000_000),
                JournalEntry(originalPath: mail.appending(path: "A1F2").path, bytes: 4_000_000,
                             outcome: .skipped(reason: "in use by com.apple.mail")),
                JournalEntry(originalPath: mail.appending(path: "7C09").path, bytes: 6_000_000,
                             outcome: .skipped(reason: "in use by com.apple.mail")),
                moved(home.appending(path: "Library/Logs/DiagnosticReports").path, 1_070_000_000),
            ],
            restorable: true)
    }
}
#endif
