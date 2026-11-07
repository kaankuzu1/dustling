import Foundation
import Testing
@testable import DustlingCore

@Suite struct StartupItemScannerTests {
    private func writePlist(_ sandbox: TestSandbox, _ relative: String, _ dict: [String: Any]) throws {
        let url = sandbox.root.appending(path: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
    }

    private func scanner(
        _ sandbox: TestSandbox, _ runner: FakeCommandRunner = FakeCommandRunner(), apps: [InstalledApp] = []
    ) -> StartupItemScanner {
        StartupItemScanner(environment: sandbox.environment, commands: runner, apps: apps)
    }

    private func item(
        _ scope: StartupScope, label: String = "com.foo.agent", plist: URL? = URL(filePath: "/tmp/x.plist")
    ) -> StartupItem {
        StartupItem(
            label: label, scope: scope, plistURL: plist, program: nil, ownerAppName: nil,
            isEnabled: true, managedInSystemSettingsOnly: false)
    }

    @Test func listsUserAndSystemAgents() throws {
        let s = try TestSandbox()
        try writePlist(s, "home/Library/LaunchAgents/com.u.agent.plist", ["Label": "com.u.agent"])
        try writePlist(s, "Library/LaunchAgents/com.s.agent.plist", ["Label": "com.s.agent"])
        try writePlist(s, "Library/LaunchDaemons/com.d.daemon.plist", ["Label": "com.d.daemon"])
        let items = scanner(s).scan()
        #expect(items.count == 3)
        #expect(items.first { $0.label == "com.u.agent" }?.scope == .userAgent)
        #expect(items.first { $0.label == "com.s.agent" }?.scope == .systemAgent)
        #expect(items.first { $0.label == "com.d.daemon" }?.scope == .systemDaemon)
        #expect(items.allSatisfy { $0.plistURL != nil && $0.isEnabled && !$0.managedInSystemSettingsOnly })
    }

    @Test func readsDisabledStateFromLaunchctl() throws {
        let s = try TestSandbox()
        try writePlist(s, "home/Library/LaunchAgents/com.foo.agent.plist", ["Label": "com.foo.agent"])
        try writePlist(s, "home/Library/LaunchAgents/com.bar.agent.plist", ["Label": "com.bar.agent"])
        try writePlist(s, "Library/LaunchDaemons/com.old.daemon.plist", ["Label": "com.old.daemon"])
        let runner = FakeCommandRunner()
        runner.setResult(
            CommandResult(
                status: 0,
                stdout: "disabled services = {\n\t\"com.foo.agent\" => disabled\n\t\"com.bar.agent\" => enabled\n}\n",
                stderr: ""),
            for: "/bin/launchctl", ["print-disabled", "gui/\(s.environment.userID)"])
        runner.setResult(
            CommandResult(status: 0, stdout: "disabled services = {\n\t\"com.old.daemon\" => true\n}\n", stderr: ""),
            for: "/bin/launchctl", ["print-disabled", "system"])
        let items = scanner(s, runner).scan()
        #expect(items.first { $0.label == "com.foo.agent" }?.isEnabled == false)
        #expect(items.first { $0.label == "com.bar.agent" }?.isEnabled == true)
        #expect(items.first { $0.label == "com.old.daemon" }?.isEnabled == false)
    }

    @Test func plistDisabledKeyMeansDisabled() throws {
        let s = try TestSandbox()
        try writePlist(s, "home/Library/LaunchAgents/com.k.plist", ["Label": "com.k", "Disabled": true])
        #expect(scanner(s).scan().first?.isEnabled == false)
    }

    @Test func ownerMatchedByProgramPath() throws {
        let s = try TestSandbox()
        let appURL = try s.app("Applications/Foo.app", bundleID: "com.foo")
        let app = InstalledApp(url: appURL, displayName: "Foo", bundleID: "com.foo", teamID: nil,
                               executableName: "App", steamAppID: nil, bytes: 1, lastUsed: nil)
        let exe = appURL.appending(path: "Contents/MacOS/Helper").path
        try writePlist(s, "home/Library/LaunchAgents/com.foo.helper.plist",
                       ["Label": "com.foo.helper", "ProgramArguments": [exe, "--bg"]])
        try writePlist(s, "home/Library/LaunchAgents/com.sibling.plist",
                       ["Label": "com.sibling", "Program": s.root.appending(path: "Applications/Foo.app.bak/x").path])
        let items = scanner(s, apps: [app]).scan()
        let owned = items.first { $0.label == "com.foo.helper" }
        #expect(owned?.ownerAppName == "Foo")
        #expect(owned?.program == exe)
        #expect(items.first { $0.label == "com.sibling" }?.ownerAppName == nil)
    }

    /// A real, parseable agent plist inside the sandbox.
    private func agent(_ s: TestSandbox, _ label: String = "com.foo.agent") throws -> StartupItem {
        try writePlist(s, "home/Library/LaunchAgents/\(label).plist", ["Label": label])
        return item(.userAgent, label: label, plist: s.root.appending(path: "home/Library/LaunchAgents/\(label).plist"))
    }

    @Test func userAgentToggleUsesLaunchctl() throws {
        let s = try TestSandbox()
        let runner = FakeCommandRunner()
        let sc = scanner(s, runner)
        let uid = s.environment.userID
        let it = try agent(s)
        let path = it.plistURL!.path(percentEncoded: false)
        #expect(sc.setEnabled(it, false) == .skipped(reason: "disabled"))
        #expect(runner.calls.map(\.arguments) == [
            ["disable", "gui/\(uid)/com.foo.agent"], ["bootout", "gui/\(uid)/com.foo.agent"],
        ])
        #expect(sc.setEnabled(it, true) == .skipped(reason: "enabled"))
        #expect(runner.calls.dropFirst(2).map(\.arguments) == [
            ["enable", "gui/\(uid)/com.foo.agent"], ["bootstrap", "gui/\(uid)", path],
        ])
        #expect(runner.calls.allSatisfy { $0.executable == "/bin/launchctl" })
    }

    @Test func notLoadedBootoutCountsAsSuccess() throws {
        let s = try TestSandbox()
        let runner = FakeCommandRunner()
        runner.setResult(CommandResult(status: 3, stdout: "", stderr: "Boot-out failed: 3: No such process"),
                         for: "/bin/launchctl", ["bootout", "gui/\(s.environment.userID)/com.foo.agent"])
        #expect(scanner(s, runner).setEnabled(try agent(s), false) == .skipped(reason: "disabled"))
    }

    @Test func alreadyBootstrappedCountsAsSuccess() throws {
        let s = try TestSandbox()
        let it = try agent(s)
        let runner = FakeCommandRunner()
        runner.setResult(CommandResult(status: 37, stdout: "", stderr: "Bootstrap failed: 37: Service already bootstrapped"),
                         for: "/bin/launchctl",
                         ["bootstrap", "gui/\(s.environment.userID)", it.plistURL!.path(percentEncoded: false)])
        #expect(scanner(s, runner).setEnabled(it, true) == .skipped(reason: "enabled"))
    }

    @Test func bootstrapIOErrorIsAFailure() throws {
        let s = try TestSandbox()
        let it = try agent(s)
        let runner = FakeCommandRunner()
        runner.setResult(CommandResult(status: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error"),
                         for: "/bin/launchctl",
                         ["bootstrap", "gui/\(s.environment.userID)", it.plistURL!.path(percentEncoded: false)])
        #expect(scanner(s, runner).setEnabled(it, true)
                == .failed(reason: "launchctl bootstrap failed: Bootstrap failed: 5: Input/output error"))
    }

    @Test func unreadableItemIsNeverToggled() throws {
        let s = try TestSandbox()
        let runner = FakeCommandRunner()
        let sc = scanner(s, runner)
        let bad = s.root.appending(path: "home/Library/LaunchAgents/broken.plist")
        try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: bad)
        try writePlist(s, "home/Library/LaunchAgents/nolabel.plist", ["Program": "/bin/true"])
        let nolabel = s.root.appending(path: "home/Library/LaunchAgents/nolabel.plist")
        let expected = DeletionOutcome.failed(reason: "can't read this startup item's settings")
        for url in [bad, nolabel, s.root.appending(path: "missing.plist")] {
            #expect(sc.setEnabled(item(.userAgent, label: "x", plist: url), false) == expected)
            #expect(sc.setEnabled(item(.userAgent, label: "x", plist: url), true) == expected)
        }
        #expect(sc.setEnabled(item(.userAgent, label: "x", plist: nil), false) == expected)
        #expect(runner.calls.isEmpty)
    }

    @Test func systemAgentEnablementComesFromGuiDomain() throws {
        let s = try TestSandbox()
        try writePlist(s, "Library/LaunchAgents/com.vendor.sysagent.plist", ["Label": "com.vendor.sysagent"])
        try writePlist(s, "Library/LaunchAgents/com.vendor.other.plist", ["Label": "com.vendor.other"])
        let uid = s.environment.userID
        let runner = FakeCommandRunner()
        runner.setResult(CommandResult(status: 0, stdout: "{\n\t\"com.vendor.sysagent\" => disabled\n}", stderr: ""),
                         for: "/bin/launchctl", ["print-disabled", "gui/\(uid)"])
        runner.setResult(CommandResult(status: 0, stdout: "{\n\t\"com.vendor.other\" => disabled\n}", stderr: ""),
                         for: "/bin/launchctl", ["print-disabled", "system"])
        let items = scanner(s, runner).scan()
        #expect(items.first { $0.label == "com.vendor.sysagent" }?.isEnabled == false)
        #expect(items.first { $0.label == "com.vendor.other" }?.isEnabled == true)
    }

    @Test func explicitEnableBeatsPlistDisabledKey() throws {
        let s = try TestSandbox()
        try writePlist(s, "home/Library/LaunchAgents/com.on.plist", ["Label": "com.on", "Disabled": true])
        try writePlist(s, "home/Library/LaunchAgents/com.absent.plist", ["Label": "com.absent", "Disabled": true])
        let runner = FakeCommandRunner()
        runner.setResult(CommandResult(status: 0, stdout: "{\n\t\"com.on\" => enabled\n}", stderr: ""),
                         for: "/bin/launchctl", ["print-disabled", "gui/\(s.environment.userID)"])
        let items = scanner(s, runner).scan()
        #expect(items.first { $0.label == "com.on" }?.isEnabled == true)
        #expect(items.first { $0.label == "com.absent" }?.isEnabled == false)
    }

    @Test func failingLaunchctlIsReported() throws {
        let s = try TestSandbox()
        let runner = FakeCommandRunner()
        _ = try agent(s)
        runner.setResult(CommandResult(status: 1, stdout: "", stderr: " boom \n"),
                         for: "/bin/launchctl", ["disable", "gui/\(s.environment.userID)/com.foo.agent"])
        #expect(scanner(s, runner).setEnabled(try agent(s), false)
                == .failed(reason: "launchctl disable failed: boom"))
    }

    @Test func systemItemsNeedAdmin() throws {
        let s = try TestSandbox()
        let runner = FakeCommandRunner()
        let sc = scanner(s, runner)
        #expect(sc.setEnabled(item(.systemDaemon), false) == .needsAdmin)
        #expect(sc.setEnabled(item(.systemAgent), true) == .needsAdmin)
        #expect(runner.calls.isEmpty)
    }

    @Test func loginItemsAreNotToggledHere() throws {
        let s = try TestSandbox()
        let runner = FakeCommandRunner()
        guard case .failed(let reason) = scanner(s, runner).setEnabled(item(.loginItem), false) else {
            Issue.record("expected failure"); return
        }
        #expect(reason.contains("System Settings"))
        #expect(runner.calls.isEmpty)
    }

    @Test func malformedPlistIsListedWithIssue() throws {
        let s = try TestSandbox()
        let url = s.root.appending(path: "home/Library/LaunchAgents/broken.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: url)
        let (items, issues) = scanner(s).scanWithIssues()
        #expect(issues.count == 1)
        if case .unreadable(let bad) = issues[0] { #expect(bad.lastPathComponent == "broken.plist") } else { Issue.record("wrong issue") }
        #expect(items.count == 1)
        #expect(items[0].label == "broken.plist")
        #expect(items[0].program == nil)
    }

    @Test func printDisabledFailureIsSurfaced() throws {
        let s = try TestSandbox()
        try writePlist(s, "home/Library/LaunchAgents/com.foo.agent.plist", ["Label": "com.foo.agent"])
        let runner = FakeCommandRunner()
        runner.setResult(CommandResult(status: 1, stdout: "", stderr: "denied"),
                         for: "/bin/launchctl", ["print-disabled", "gui/\(s.environment.userID)"])
        let result = scanner(s, runner).scanWithIssues()
        #expect(result.items.count == 1)
        #expect(result.issues == [
            .commandFailed(command: "launchctl print-disabled gui/\(s.environment.userID)", reason: "denied"),
        ])
    }

    @Test func missingDirectoriesAreSilent() throws {
        let s = try TestSandbox()
        let result = scanner(s).scanWithIssues()
        #expect(result.items.isEmpty)
        #expect(result.issues.isEmpty)
    }
}
