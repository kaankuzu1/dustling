import Testing
import Foundation
@testable import DustlingCore

@Suite struct LeftoverFinderTests {
    let sandbox: TestSandbox
    let runner = FakeCommandRunner()

    init() throws { sandbox = try TestSandbox() }

    private func finder() -> LeftoverFinder {
        LeftoverFinder(environment: sandbox.environment, sizer: DirectorySizer(), commands: runner)
    }

    private func app(
        bundleID: String? = "com.example.foo", teamID: String? = nil, name: String = "Foo", steam: String? = nil
    ) throws -> InstalledApp {
        // The on-disk plist always gets a sane ID; the struct carries the (possibly hostile) value.
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        let url = try sandbox.app("Applications/\(safeName).app", bundleID: "com.example.stub", executable: "helper")
        return InstalledApp(
            url: url, displayName: name, bundleID: bundleID, teamID: teamID,
            executableName: "helper", steamAppID: steam, bytes: 0, lastUsed: nil)
    }

    private func find(_ items: [Leftover], _ suffix: String) -> Leftover? {
        items.first { $0.url.path.hasSuffix(suffix) }
    }

    @Test func exactCachesArePreselected() throws {
        try sandbox.file("home/Library/Caches/com.example.foo/data.bin", bytes: 4096)
        let items = finder().leftovers(for: try app())
        let item = try #require(find(items, "Library/Caches/com.example.foo"))
        #expect(item.kind == .caches)
        #expect(item.match == .exact)
        #expect(item.preselected)
        #expect(item.bytes > 0)
    }

    @Test func applicationSupportIsUserDataAndUnchecked() throws {
        try sandbox.file("home/Library/Application Support/com.example.foo/db.sqlite")
        let item = try #require(find(finder().leftovers(for: try app()), "Application Support/com.example.foo"))
        #expect(item.kind == .applicationSupport)
        #expect(item.mayContainUserData)
        #expect(!item.preselected)
    }

    @Test func groupContainerMatchesTeamID() throws {
        try sandbox.file("home/Library/Group Containers/ABCDE12345.shared/x")
        try sandbox.file("home/Library/Group Containers/OTHER99999.shared/x")
        let items = finder().leftovers(for: try app(teamID: "ABCDE12345"))
        let item = try #require(find(items, "Group Containers/ABCDE12345.shared"))
        #expect(item.kind == .groupContainer)
        #expect(item.mayContainUserData)
        #expect(!item.preselected)
        #expect(find(items, "OTHER99999.shared") == nil)
        #expect(find(finder().leftovers(for: try app(teamID: nil)), "Group Containers/ABCDE12345.shared") == nil)
    }

    @Test func otherExactLocations() throws {
        try sandbox.file("home/Library/Preferences/com.example.foo.plist")
        try sandbox.file("home/Library/Preferences/ByHost/com.example.foo.ABC-123.plist")
        try sandbox.file("home/Library/Preferences/ByHost/com.example.foobar.ABC.plist")
        try sandbox.file("home/Library/Saved Application State/com.example.foo.savedState/w")
        try sandbox.file("home/Library/HTTPStorages/com.example.foo/x")
        try sandbox.file("home/Library/HTTPStorages/com.example.foo.binarycookies")
        try sandbox.file("home/Library/WebKit/com.example.foo/x")
        try sandbox.file("home/Library/Logs/com.example.foo/x")
        try sandbox.file("home/Library/Cookies/com.example.foo.binarycookies")
        try sandbox.file("home/Library/Containers/com.example.foo/Data/x")
        let items = finder().leftovers(for: try app())
        #expect(find(items, "Preferences/com.example.foo.plist")?.kind == .preferences)
        #expect(find(items, "ByHost/com.example.foo.ABC-123.plist")?.kind == .preferences)
        #expect(find(items, "ByHost/com.example.foobar.ABC.plist") == nil)
        #expect(find(items, "com.example.foo.savedState")?.kind == .savedState)
        #expect(find(items, "HTTPStorages/com.example.foo")?.kind == .httpStorage)
        #expect(find(items, "HTTPStorages/com.example.foo.binarycookies")?.kind == .httpStorage)
        #expect(find(items, "WebKit/com.example.foo")?.kind == .webKit)
        #expect(find(items, "Logs/com.example.foo")?.kind == .logs)
        #expect(find(items, "Cookies/com.example.foo.binarycookies")?.kind == .cookies)
        let container = try #require(find(items, "Containers/com.example.foo"))
        #expect(container.kind == .container && container.mayContainUserData && !container.preselected)
        for kind in [LeftoverKind.preferences, .savedState, .httpStorage, .webKit, .logs, .cookies] {
            #expect(items.filter { $0.kind == kind }.allSatisfy { $0.preselected })
        }
    }

    @Test func nameBasedMatches() throws {
        try sandbox.file("home/Library/Application Support/Foo/save.dat")
        try sandbox.file("home/Library/Caches/Foo/c")
        try sandbox.file("home/Library/Logs/Foo/l")
        try sandbox.file("home/Library/Caches/foo/c")
        let items = finder().leftovers(for: try app())
        let support = try #require(find(items, "Application Support/Foo"))
        #expect(support.match == .nameBased && support.mayContainUserData && !support.preselected)
        let cache = try #require(find(items, "Caches/Foo"))
        #expect(cache.match == .nameBased && !cache.mayContainUserData && !cache.preselected)
        #expect(find(items, "Logs/Foo")?.match == .nameBased)
        #expect(items.filter { $0.url.lastPathComponent == "foo" }.isEmpty)
    }

    private func writeLaunchPlist(_ path: String, _ dict: [String: Any]) throws {
        let url = try sandbox.file(path)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
    }

    @Test func launchAgentMatchedByProgramPath() throws {
        let a = try app()
        try writeLaunchPlist("home/Library/LaunchAgents/unrelated-name.plist", [
            "Label": "zzz.unrelated",
            "ProgramArguments": ["\(a.url.path)/Contents/MacOS/helper", "--daemon"],
        ])
        try writeLaunchPlist("home/Library/LaunchAgents/other.plist", [
            "Label": "zzz.other", "ProgramArguments": ["/usr/bin/true"],
        ])
        try writeLaunchPlist("home/Library/LaunchAgents/sibling.plist", [
            "Label": "zzz.sibling", "Program": "\(a.url.path)Evil/Contents/MacOS/x",
        ])
        let items = finder().leftovers(for: a)
        let item = try #require(find(items, "LaunchAgents/unrelated-name.plist"))
        #expect(item.kind == .launchAgent && item.match == .exact)
        #expect(!item.requiresAdmin && item.preselected)
        #expect(find(items, "other.plist") == nil)
        #expect(find(items, "sibling.plist") == nil)
    }

    @Test func systemLaunchItemsRequireAdmin() throws {
        try writeLaunchPlist("Library/LaunchDaemons/com.example.foo.daemon.plist", ["Label": "com.example.foo.daemon"])
        try writeLaunchPlist("Library/LaunchAgents/com.example.foo.plist", ["Label": "com.example.foo"])
        try sandbox.file("Library/PrivilegedHelperTools/com.example.foo.helper")
        try sandbox.file("Library/PrivilegedHelperTools/com.example.foobar.helper")
        let items = finder().leftovers(for: try app())
        #expect(find(items, "LaunchDaemons/com.example.foo.daemon.plist")?.kind == .launchDaemon)
        #expect(find(items, "LaunchDaemons/com.example.foo.daemon.plist")?.requiresAdmin == true)
        #expect(find(items, "LaunchAgents/com.example.foo.plist")?.requiresAdmin == true)
        let helper = try #require(find(items, "PrivilegedHelperTools/com.example.foo.helper"))
        #expect(helper.kind == .privilegedHelper && helper.requiresAdmin && helper.match == .exact)
        #expect(find(items, "com.example.foobar.helper") == nil)
    }

    @Test func labelPrefixRequiresDotBoundary() throws {
        try writeLaunchPlist("home/Library/LaunchAgents/a.plist", ["Label": "com.example.foobar.agent"])
        try writeLaunchPlist("home/Library/LaunchAgents/b.plist", ["Label": "com.example.foo.agent"])
        try writeLaunchPlist("home/Library/LaunchAgents/c.plist", ["Label": "com.example.foo"])
        try sandbox.file("home/Library/LaunchAgents/broken.plist")  // unparsable: ignored
        let items = finder().leftovers(for: try app())
        #expect(find(items, "LaunchAgents/a.plist") == nil)
        #expect(find(items, "LaunchAgents/b.plist") != nil)
        #expect(find(items, "LaunchAgents/c.plist") != nil)
        #expect(find(items, "broken.plist") == nil)
    }

    @Test func steamGameDataIsReviewItem() throws {
        try sandbox.file(
            "home/Library/Application Support/Steam/steamapps/appmanifest_400.acf",
            bytes: 0)
        let manifest = sandbox.root.appending(path: "home/Library/Application Support/Steam/steamapps/appmanifest_400.acf")
        try Data("\"AppState\"\n{\n\t\"appid\"\t\t\"400\"\n\t\"installdir\"\t\t\"Portal\"\n}\n".utf8).write(to: manifest)
        try sandbox.file("home/Library/Application Support/Steam/steamapps/common/Portal/portal.dat")
        let items = finder().leftovers(for: try app(bundleID: nil, name: "Portal", steam: "400"))
        let game = try #require(find(items, "steamapps/common/Portal"))
        #expect(game.kind == .steamGameData && game.match == .exact)
        #expect(game.mayContainUserData && !game.preselected)
        let mf = try #require(find(items, "appmanifest_400.acf"))
        #expect(mf.kind == .steamGameData && !mf.preselected)
    }

    @Test func packageReceiptsNeedAdmin() throws {
        let a = try app()
        runner.setResult(
            CommandResult(status: 0, stdout: "volume: /\npath: \(a.url.path)\n\npkgid: com.example.foo.pkg\n", stderr: ""),
            for: "/usr/sbin/pkgutil", ["--file-info", a.url.path])
        let items = finder().leftovers(for: a)
        let receipt = try #require(items.first { $0.kind == .packageReceipt })
        #expect(receipt.requiresAdmin)
        #expect(receipt.url.path == "/private/var/db/receipts/com.example.foo.pkg.plist")
        #expect(receipt.kind == .packageReceipt && receipt.match == .exact)
        #expect(runner.calls.count == 1)
    }

    @Test func pkgutilFailureMeansNoReceipts() throws {
        runner.setDefault(CommandResult(status: 1, stdout: "pkgid: com.bad\n", stderr: "No receipt"))
        #expect(finder().leftovers(for: try app()).filter { $0.kind == .packageReceipt }.isEmpty)
        runner.setDefaultError(CocoaError(.fileNoSuchFile))
        #expect(finder().leftovers(for: try app()).filter { $0.kind == .packageReceipt }.isEmpty)
    }

    @Test func nonexistentPathsAreOmitted() throws {
        #expect(finder().leftovers(for: try app()).isEmpty)
    }

    @Test func duplicateUrlsAreCollapsed() throws {
        try sandbox.file("home/Library/Caches/Foo/c")
        let a = try app(bundleID: "Foo", name: "Foo")
        let items = finder().leftovers(for: a)
        #expect(items.filter { $0.url.lastPathComponent == "Foo" && $0.url.path.contains("Caches") }.count == 1)
    }

    @Test func maliciousBundleIDYieldsNothing() throws {
        try sandbox.file("home/Documents/precious.txt")
        for bad in ["../../Documents", "..", ".", "", "a/b", "a:b", "x\0y"] {
            let a = try app(bundleID: bad, teamID: bad, name: "Safe")
            let items = finder().leftovers(for: a)
            #expect(items.isEmpty, "bundleID \(bad.debugDescription) produced \(items.map(\.url.path))")
        }
    }

    @Test func maliciousSteamInstallDirYieldsNothing() throws {
        try sandbox.file("home/Documents/precious.txt")
        let dir = try sandbox.directory("home/Library/Application Support/Steam/steamapps")
        try Data("\"installdir\"\t\t\"../../../Documents\"\n".utf8).write(to: dir.appending(path: "appmanifest_9.acf"))
        let items = finder().leftovers(for: try app(bundleID: nil, name: "Safe", steam: "9"))
        #expect(items.isEmpty, "\(items.map(\.url.path))")
    }

    @Test func maliciousDisplayNameYieldsNothing() throws {
        try sandbox.file("home/Documents/precious.txt")
        let items = finder().leftovers(for: try app(bundleID: nil, name: "../../Documents"))
        #expect(items.isEmpty)
    }

    @Test func everyLeftoverParentIsADeclaredLocation() throws {
        try sandbox.file("home/Library/Caches/com.example.foo/c")
        try sandbox.file("home/Library/Application Support/com.example.foo/c")
        try sandbox.file("home/Library/Preferences/ByHost/com.example.foo.X.plist")
        try sandbox.file("home/Library/Caches/Foo/c")
        try sandbox.file("Library/PrivilegedHelperTools/com.example.foo.helper")
        try sandbox.file("home/Library/Application Support/Steam/steamapps/common/Foo/g")
        try sandbox.file("home/Library/Application Support/Steam/steamapps/common/Bar/g")
        try Data("\"installdir\"\t\t\"Bar\"\n".utf8).write(
            to: sandbox.root.appending(path: "home/Library/Application Support/Steam/steamapps/appmanifest_7.acf"))
        runner.setDefault(CommandResult(status: 0, stdout: "pkgid: com.example.foo.pkg\n", stderr: ""))
        let allowed = Set(LeftoverFinder.locationDirectories(sandbox.environment).map(\.standardizedFileURL.path))
        let withSteam = try app(steam: "8")
        let withManifest = try app(bundleID: nil, name: "Other", steam: "7")
        let items = finder().leftovers(for: withSteam) + finder().leftovers(for: withManifest)
        #expect(items.contains { $0.kind == .steamGameData })
        #expect(items.contains { $0.kind == .packageReceipt })
        #expect(items.count >= 7)
        for item in items {
            #expect(allowed.contains(item.url.deletingLastPathComponent().standardizedFileURL.path), "\(item.url.path)")
        }
    }

    @Test func locationDirectoriesAreFixed() throws {
        let env = sandbox.environment
        let dirs = LeftoverFinder.locationDirectories(env).map(\.standardizedFileURL.path)
        let lib = env.userLibrary
        for expected in [
            lib.appending(path: "Caches"), lib.appending(path: "LaunchAgents"), lib.appending(path: "Preferences/ByHost"),
            lib.appending(path: "Application Support/Steam/steamapps"),
            lib.appending(path: "Application Support/Steam/steamapps/common"),
            env.systemLibrary.appending(path: "LaunchDaemons"), env.systemLibrary.appending(path: "PrivilegedHelperTools"),
        ] {
            #expect(dirs.contains(expected.standardizedFileURL.path), "\(expected.path)")
        }
        #expect(!dirs.contains(lib.standardizedFileURL.path))
        #expect(!dirs.contains(env.home.standardizedFileURL.path))
        #expect(!dirs.contains(env.home.appending(path: "Downloads").standardizedFileURL.path))
    }

    @Test func graphemeClusterSlashBypassIsRejected() throws {
        // One ".." from Library/<dir> lands in Library, so plant the would-be targets there.
        try sandbox.file("home/Library/\u{301}x/keep.txt")
        try sandbox.file("home/Library/\u{200D}Mail/keep.txt")
        try sandbox.file("home/Library/\u{FE0F}Mail/keep.txt")
        try sandbox.directory("home/Library/Caches")
        for bad in ["../\u{301}x", "../\u{200D}Mail", "../\u{FE0F}Mail"] {
            #expect(!LeftoverFinder.isSafeComponent(bad), "\(bad.debugDescription)")
            let items = finder().leftovers(for: try app(bundleID: bad, name: "Safe"))
            #expect(items.isEmpty, "\(bad.debugDescription) -> \(items.map(\.url.path))")
        }
    }

    @Test func twoComponentBundleIDKeepsDirectMatchesOnly() throws {
        try sandbox.file("home/Library/Caches/com.foo/c")
        try writeLaunchPlist("home/Library/LaunchAgents/eq.plist", ["Label": "com.foo"])
        try writeLaunchPlist("home/Library/LaunchAgents/pre.plist", ["Label": "com.foo.agent"])
        let items = finder().leftovers(for: try app(bundleID: "com.foo", name: "Safe"))
        #expect(find(items, "Caches/com.foo")?.preselected == true)
        #expect(find(items, "LaunchAgents/eq.plist") != nil)
        #expect(find(items, "LaunchAgents/pre.plist") == nil)
    }

    @Test func shortBundleIDsOnlyMatchByEquality() throws {
        try writeLaunchPlist("home/Library/LaunchAgents/a.plist", ["Label": "com.anything.agent"])
        try writeLaunchPlist("home/Library/LaunchAgents/b.plist", ["Label": "MyTool.x"])
        try sandbox.file("Library/PrivilegedHelperTools/com.anything.helper")
        try sandbox.file("Library/PrivilegedHelperTools/MyTool.x")
        try sandbox.file("home/Library/Preferences/ByHost/com.anything.UUID.plist")
        try sandbox.file("home/Library/Preferences/ByHost/MyTool.UUID.plist")
        for bid in ["com", "MyTool"] {
            #expect(finder().leftovers(for: try app(bundleID: bid, name: "Safe")).isEmpty)
        }
        try writeLaunchPlist("home/Library/LaunchAgents/c.plist", ["Label": "MyTool"])
        #expect(find(finder().leftovers(for: try app(bundleID: "MyTool", name: "Safe")), "LaunchAgents/c.plist") != nil)
    }

    @Test func invalidTeamIDsYieldNoGroupContainers() throws {
        try sandbox.file("home/Library/Group Containers/ABC.x/f")
        try sandbox.file("home/Library/Group Containers/../x.y/f")
        for t in ["../x", "ABC", "abcde12345", "ABCDE123456"] {
            let items = finder().leftovers(for: try app(bundleID: nil, teamID: t, name: "Safe"))
            #expect(items.isEmpty, "\(t)")
        }
    }

    @Test func byHostRequiresSingleSegment() throws {
        try sandbox.file("home/Library/Preferences/ByHost/com.google.Chrome.UUID1.plist")
        try sandbox.file("home/Library/Preferences/ByHost/com.google.Chrome.canary.UUID2.plist")
        let items = finder().leftovers(for: try app(bundleID: "com.google.Chrome", name: "Chrome"))
        #expect(find(items, "com.google.Chrome.UUID1.plist") != nil)
        #expect(find(items, "canary.UUID2.plist") == nil)
    }

    @Test func moreSpecificInstalledAppOwnsItsFiles() throws {
        try writeLaunchPlist("home/Library/LaunchAgents/canary.plist", ["Label": "com.google.Chrome.canary.agent"])
        try writeLaunchPlist("home/Library/LaunchAgents/chrome.plist", ["Label": "com.google.Chrome.agent"])
        try sandbox.file("Library/PrivilegedHelperTools/com.google.Chrome.canary.helper")
        try sandbox.file("Library/PrivilegedHelperTools/com.google.Chrome.helper")
        let chrome = try app(bundleID: "com.google.Chrome", name: "Chrome")
        let canary = try app(bundleID: "com.google.Chrome.canary", name: "Chrome Canary")
        let items = finder().leftovers(for: chrome, among: [chrome, canary])
        #expect(find(items, "chrome.plist") != nil)
        #expect(find(items, "PrivilegedHelperTools/com.google.Chrome.helper") != nil)
        #expect(find(items, "canary.plist") == nil)
        #expect(find(items, "Chrome.canary.helper") == nil)
        let canaryItems = finder().leftovers(for: canary, among: [chrome, canary])
        #expect(find(canaryItems, "canary.plist") != nil)
    }

    @Test func sharedTeamIDMakesGroupContainerNameBased() throws {
        try sandbox.file("home/Library/Group Containers/ABCDE12345.shared/x")
        let a = try app(bundleID: "com.example.one", teamID: "ABCDE12345", name: "One")
        let b = try app(bundleID: "com.example.two", teamID: "ABCDE12345", name: "Two")
        let shared = try #require(find(finder().leftovers(for: a, among: [a, b]), "ABCDE12345.shared"))
        #expect(shared.match == .nameBased && !shared.preselected)
        let alone = try #require(find(finder().leftovers(for: a, among: [a]), "ABCDE12345.shared"))
        #expect(alone.match == .exact)
    }

    @Test func unlistableLocationReportsFullDiskAccess() throws {
        let caches = try sandbox.directory("home/Library/Caches")
        try sandbox.file("home/Library/Caches/com.example.foo/x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: caches.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: caches.path) }
        let result = finder().leftoversWithIssues(for: try app())
        #expect(result.issues.contains(.missingFullDiskAccess(caches)))
        #expect(find(result.leftovers, "Caches/com.example.foo") == nil)
    }

    @Test func missingDirectoriesAreSilent() throws {
        #expect(finder().leftoversWithIssues(for: try app()).issues.isEmpty)
    }

    @Test func pkgutilLaunchFailureIsReported() throws {
        runner.setDefaultError(CocoaError(.fileNoSuchFile))
        let result = finder().leftoversWithIssues(for: try app())
        #expect(result.issues.contains { if case .commandFailed(let c, _) = $0 { c == "pkgutil --file-info" } else { false } })
        // Non-zero exit is not an issue.
        runner.setDefault(CommandResult(status: 1, stdout: "", stderr: "No receipt"))
        #expect(finder().leftoversWithIssues(for: try app()).issues.isEmpty)
    }
    // MARK: - Steam fallback, shared install folders, duplicate names (R27 amended, Important #10)

    private let steamapps = "home/Library/Application Support/Steam/steamapps"

    private func manifest(_ id: String, installdir: String) throws {
        let url = try sandbox.file("\(steamapps)/appmanifest_\(id).acf")
        try Data("\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"installdir\"\t\t\"\(installdir)\"\n}\n".utf8)
            .write(to: url)
    }

    @Test func missingManifestFallsBackToFolderNamedLikeTheApp() throws {
        try sandbox.file("\(steamapps)/common/Portal/portal.dat", bytes: 4096)
        try manifest("220", installdir: "Half-Life 2")
        let items = finder().leftovers(for: try app(bundleID: nil, name: "Portal", steam: "400"))
        let game = try #require(find(items, "steamapps/common/Portal"))
        #expect(game.kind == .steamGameData && game.match == .nameBased)
        #expect(game.mayContainUserData && !game.preselected && !game.requiresAdmin)
        #expect(game.bytes > 0)
        #expect(game.note == "matched by folder name, no Steam manifest found")
        #expect(find(items, "appmanifest_400.acf") == nil)
        #expect(items.count == 1)
    }

    @Test func fallbackIsRefusedWhenAnotherManifestOwnsTheFolder() throws {
        try sandbox.file("\(steamapps)/common/Portal/portal.dat")
        try manifest("401", installdir: "portal")   // same folder on a case-insensitive volume
        let result = finder().leftoversWithIssues(for: try app(bundleID: nil, name: "Portal", steam: "400"))
        #expect(find(result.leftovers, "steamapps/common/Portal") == nil)
        #expect(result.issues.isEmpty)
    }

    @Test func fallbackIsRefusedWhenAnotherManifestCantBeRead() throws {
        try sandbox.file("\(steamapps)/common/Portal/portal.dat")
        try manifest("401", installdir: "Something Else")
        let other = sandbox.root.appending(path: "\(steamapps)/appmanifest_401.acf")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: other.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: other.path) }
        let result = finder().leftoversWithIssues(for: try app(bundleID: nil, name: "Portal", steam: "400"))
        #expect(find(result.leftovers, "steamapps/common/Portal") == nil)
        #expect(result.issues == [.unreadable(other)])
    }

    @Test func sharedInstallFolderIsNameBasedWithNote() throws {
        try sandbox.file("\(steamapps)/common/Half-Life 2/hl2.dat")
        for id in ["220", "340", "380", "420"] { try manifest(id, installdir: "Half-Life 2") }
        let items = finder().leftovers(for: try app(bundleID: nil, name: "Half-Life 2 Lost Coast", steam: "340"))
        let game = try #require(find(items, "steamapps/common/Half-Life 2"))
        #expect(game.kind == .steamGameData && game.match == .nameBased && !game.preselected)
        #expect(game.note == "shared with 3 other Steam games")
        let own = try #require(find(items, "appmanifest_340.acf"))
        #expect(own.match == .exact && own.note == nil)
        #expect(find(items, "appmanifest_220.acf") == nil)
    }

    @Test func sharedWithOneOtherGameReadsSingular() throws {
        try sandbox.file("\(steamapps)/common/Half-Life 2/hl2.dat")
        try manifest("220", installdir: "Half-Life 2")
        try manifest("340", installdir: "Half-Life 2")
        let items = finder().leftovers(for: try app(bundleID: nil, name: "Lost Coast", steam: "340"))
        #expect(find(items, "steamapps/common/Half-Life 2")?.note == "shared with 1 other Steam game")
    }

    @Test func unsharedManifestFolderStaysExactWithoutNote() throws {
        try sandbox.file("\(steamapps)/common/Portal/portal.dat")
        try manifest("400", installdir: "Portal")
        try manifest("220", installdir: "Half-Life 2")
        let game = try #require(find(finder().leftovers(for: try app(bundleID: nil, name: "Portal", steam: "400")),
                                     "steamapps/common/Portal"))
        #expect(game.match == .exact && game.note == nil)
    }

    @Test func duplicateDisplayNameSkipsNameBasedMatches() throws {
        try sandbox.file("home/Library/Application Support/Steam/registry.vdf")
        try sandbox.file("home/Library/Caches/Steam/c")
        try sandbox.file("home/Library/Logs/Steam/l")
        let a = try app(bundleID: "com.valvesoftware.steam", name: "Steam")
        let otherURL = try sandbox.app("home/Applications/CrossOver/Steam.app", bundleID: nil)
        let b = InstalledApp(
            url: otherURL, displayName: "steam", bundleID: nil, teamID: nil,
            executableName: "App", steamAppID: nil, bytes: 0, lastUsed: nil)
        let items = finder().leftovers(for: a, among: [a, b])
        #expect(find(items, "Application Support/Steam") == nil)
        #expect(find(items, "Caches/Steam") == nil)
        #expect(find(items, "Logs/Steam") == nil)
        let alone = finder().leftovers(for: a, among: [a])
        #expect(find(alone, "Application Support/Steam") != nil)
        #expect(find(alone, "Caches/Steam") != nil)
        #expect(find(alone, "Logs/Steam") != nil)
    }

    @Test func duplicateDisplayNameAlsoBlocksSteamFallback() throws {
        try sandbox.file("\(steamapps)/common/Portal/portal.dat")
        let a = try app(bundleID: nil, name: "Portal", steam: "400")
        let otherURL = try sandbox.app("home/Applications/Portal.app", bundleID: nil)
        let b = InstalledApp(
            url: otherURL, displayName: "Portal", bundleID: nil, teamID: nil,
            executableName: "App", steamAppID: "500", bytes: 0, lastUsed: nil)
        #expect(find(finder().leftovers(for: a, among: [a, b]), "steamapps/common/Portal") == nil)
    }

    @Test func hostileNamesNeverReachTheSteamFallback() throws {
        try sandbox.file("home/Documents/precious.txt")
        try sandbox.file("\(steamapps)/common/x/y")
        let url = try sandbox.app("Applications/Safe.app", bundleID: nil)
        for bad in ["../../../../Documents", "..", ".", "", "a/b", "a:b", "x\0y", "../\u{301}x"] {
            let hostile = InstalledApp(
                url: url, displayName: bad, bundleID: nil, teamID: nil,
                executableName: "App", steamAppID: "9", bytes: 0, lastUsed: nil)
            let items = finder().leftovers(for: hostile)
            #expect(items.isEmpty, "\(bad.debugDescription) -> \(items.map(\.url.path))")
        }
    }
}

