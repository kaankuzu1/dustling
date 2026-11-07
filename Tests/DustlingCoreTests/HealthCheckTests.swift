import Foundation
import Testing
@testable import DustlingCore

struct HealthCheckTests {
    private let tccPath = "home/Library/Application Support/com.apple.TCC/TCC.db"
    private let tmutil = "/usr/bin/tmutil"
    private let fdaSentence = "Full Disk Access is off, so some folders can't be scanned."

    @Test func settingsURLIsVerbatim() {
        #expect(FullDiskAccessProbe.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    @Test func fdaGrantedWhenReadable() throws {
        let sandbox = try TestSandbox()
        try sandbox.file(tccPath)
        #expect(FullDiskAccessProbe(environment: sandbox.environment).status() == .granted)
    }

    @Test func fdaDeniedWhenTCCUnreadable() throws {
        let sandbox = try TestSandbox()
        let url = try sandbox.file(tccPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        #expect(FullDiskAccessProbe(environment: sandbox.environment).status() == .denied)
    }

    @Test func fdaUnknownWhenMissing() throws {
        let sandbox = try TestSandbox()
        #expect(FullDiskAccessProbe(environment: sandbox.environment).status() == .unknown)
    }

    @Test func snapshotCountParsesTmutil() throws {
        let sandbox = try TestSandbox()
        let runner = FakeCommandRunner()
        runner.setResult(
            CommandResult(status: 0, stdout: """
                Snapshots for volume group containing disk /:
                com.apple.TimeMachine.2026-11-01-120000.local
                com.apple.TimeMachine.2026-11-02-120000.local

                """, stderr: ""),
            for: tmutil, ["listlocalsnapshots", sandbox.root.path])
        let info = try StorageReader(commands: runner).read(volume: sandbox.root)
        #expect(info.localSnapshotCount == 2)
        #expect(info.totalBytes > 0)
        #expect(info.availableBytes > 0)
        #expect(info.availableForImportantUsage > 0)
    }

    @Test func tmutilFailureIsReportedNotSilentlyZero() throws {
        let sandbox = try TestSandbox()
        let runner = FakeCommandRunner(default: CommandResult(status: 1, stdout: "", stderr: " boom \n"))
        let (info, problems) = try StorageReader(commands: runner).readWithIssues(volume: sandbox.root)
        #expect(info.localSnapshotCount == 0)
        #expect(problems == ["Couldn't check Time Machine local snapshots: boom"])
    }

    @Test func problemsArePlainSentences() throws {
        let sandbox = try TestSandbox()
        try sandbox.file(tccPath)
        let url = sandbox.root.appending(path: tccPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let check = HealthCheck(environment: sandbox.environment, commands: FakeCommandRunner(), volume: sandbox.root)
        let report = check.run()
        #expect(report.fullDiskAccess == .denied)
        #expect(report.problems.contains(fdaSentence))
        #expect(report.storage != nil)
    }

    @Test func storageUnavailableAddsProblem() throws {
        let sandbox = try TestSandbox()
        let missing = sandbox.root.appending(path: "nope")
        let report = HealthCheck(environment: sandbox.environment, commands: FakeCommandRunner(), volume: missing).run()
        #expect(report.storage == nil)
        #expect(report.problems.contains { $0.hasPrefix("Storage numbers unavailable: ") })
    }
}
