import Foundation
import Testing
@testable import DustlingCore

@Suite struct StartupChangeRecorderTests {
    private struct Rig {
        let sandbox: TestSandbox
        let runner: FakeCommandRunner
        let journal: RunJournal
        let logsDirectory: URL
        let recorder: StartupChangeRecorder
    }

    private func rig(journalDirectory: URL? = nil) throws -> Rig {
        let sandbox = try TestSandbox()
        let runner = FakeCommandRunner()
        let journal = RunJournal(directory: journalDirectory ?? sandbox.root.appending(path: "history"))
        let logs = sandbox.root.appending(path: "logs")
        let scanner = StartupItemScanner(environment: sandbox.environment, commands: runner, apps: [])
        let recorder = StartupChangeRecorder(scanner: scanner, journal: journal, logger: RunLogger(directory: logs))
        return Rig(sandbox: sandbox, runner: runner, journal: journal, logsDirectory: logs, recorder: recorder)
    }

    private func userAgent(_ sandbox: TestSandbox, label: String = "com.foo.agent", valid: Bool = true) throws -> StartupItem {
        let url = sandbox.root.appending(path: "home/Library/LaunchAgents/\(label).plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dict: [String: Any] = valid ? ["Label": label] : ["Nothing": 1]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        return StartupItem(
            label: label, scope: .userAgent, plistURL: url, program: nil, ownerAppName: nil,
            isEnabled: true, managedInSystemSettingsOnly: false)
    }

    private func logText(_ dir: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    @Test func toggleIsJournaledAndLogged() throws {
        let r = try rig()
        let item = try userAgent(r.sandbox)
        let record = r.recorder.setEnabled(item, false)

        #expect(record.kind == .startupChange)
        #expect(record.restorable == false)
        #expect(record.inProgress == false)
        #expect(record.entries.count == 1)
        #expect(record.entries[0].originalPath == item.plistURL?.path(percentEncoded: false))
        #expect(record.entries[0].outcome == .skipped(reason: "disabled"))
        #expect(record.entries[0].bytes == 0)

        let saved = try r.journal.all()
        #expect(saved.count == 1)
        #expect(saved[0].id == record.id)
        #expect(saved[0].entries == record.entries)
        let log = try logText(r.logsDirectory)
        #expect(log.contains("kind=startupChange"))
        #expect(log.contains(item.plistURL!.path(percentEncoded: false)))
        #expect(log.contains(DeletionOutcome.skipped(reason: "disabled").label))

        let enabled = r.recorder.setEnabled(item, true)
        #expect(enabled.entries[0].outcome == .skipped(reason: "enabled"))
        #expect(try r.journal.all().count == 2)
    }

    @Test func failedToggleIsJournaledAsFailed() throws {
        let r = try rig()
        let item = try userAgent(r.sandbox)
        r.runner.setResult(
            CommandResult(status: 5, stdout: "", stderr: "Boot-out failed"),
            for: "/bin/launchctl", ["disable", "gui/\(r.sandbox.environment.userID)/com.foo.agent"])
        let record = r.recorder.setEnabled(item, false)

        #expect(record.entries.count == 1)
        guard case .failed(let reason) = record.entries[0].outcome else {
            Issue.record("expected failed, got \(record.entries[0].outcome)"); return
        }
        #expect(reason.contains("launchctl disable failed"))
        #expect(try r.journal.all().first?.entries == record.entries)
        #expect(try logText(r.logsDirectory).contains(record.entries[0].outcome.label))

        // Unreadable plist is also a recorded failure, using the plist path.
        let bad = try userAgent(r.sandbox, label: "com.bad.agent", valid: false)
        let badRecord = r.recorder.setEnabled(bad, true)
        #expect(badRecord.entries[0].outcome == .failed(reason: "can't read this startup item's settings"))
        #expect(badRecord.entries[0].originalPath == bad.plistURL?.path(percentEncoded: false))
    }

    @Test func loginItemToggleRecordsSystemSettingsFailure() throws {
        let r = try rig()
        let item = StartupItem(
            label: "Some Login Item", scope: .loginItem, plistURL: nil, program: nil, ownerAppName: nil,
            isEnabled: true, managedInSystemSettingsOnly: true)
        let record = r.recorder.setEnabled(item, false)

        #expect(record.entries.count == 1)
        #expect(record.entries[0].originalPath == "Some Login Item")
        guard case .failed(let reason) = record.entries[0].outcome else {
            Issue.record("expected failed"); return
        }
        #expect(reason.contains("System Settings"))
        #expect(r.runner.calls.isEmpty)
        #expect(try r.journal.all().first?.entries == record.entries)
    }

    @Test func systemItemRecordsNeedsAdmin() throws {
        let r = try rig()
        let item = StartupItem(
            label: "com.sys.daemon", scope: .systemDaemon,
            plistURL: URL(filePath: "/Library/LaunchDaemons/com.sys.daemon.plist"), program: nil,
            ownerAppName: nil, isEnabled: true, managedInSystemSettingsOnly: false)
        let record = r.recorder.setEnabled(item, false)
        #expect(record.entries.map(\.outcome) == [.needsAdmin])
        #expect(try r.journal.all().first?.entries == record.entries)
    }

    @Test func historyAndLogFailuresAreRecordedOnce() throws {
        let sandbox = try TestSandbox()
        // A file where the history directory should be, and where the logs directory should be.
        let blockedHistory = try sandbox.file("blocked-history")
        let blockedLogs = try sandbox.file("blocked-logs")
        let scanner = StartupItemScanner(environment: sandbox.environment, commands: FakeCommandRunner(), apps: [])
        let recorder = StartupChangeRecorder(
            scanner: scanner, journal: RunJournal(directory: blockedHistory),
            logger: RunLogger(directory: blockedLogs))
        let item = StartupItem(
            label: "Login", scope: .loginItem, plistURL: nil, program: nil, ownerAppName: nil,
            isEnabled: true, managedInSystemSettingsOnly: true)
        let record = recorder.setEnabled(item, false)

        let paths = record.entries.map { $0.originalPath }
        #expect(paths.filter { $0 == "<history>" }.count == 1)
        #expect(paths.filter { $0 == "<log>" }.count == 1)
        #expect(paths.first == "Login")
        for e in record.entries where e.originalPath.hasPrefix("<") {
            guard case .failed = e.outcome else { Issue.record("expected failed"); continue }
            #expect(e.bytes == 0)
        }
    }
}
