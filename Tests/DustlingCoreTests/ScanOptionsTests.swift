import Foundation
import Testing
@testable import DustlingCore

@Suite struct ScanOptionsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func scan(_ sb: TestSandbox, options: ScanOptions) async -> [JunkCategoryID: CategoryScan] {
        let catalog = JunkCatalog.standard(sb.environment, now: now, options: options)
        let scanner = JunkScanner(environment: sb.environment, runningBundleIDs: { [] })
        let results = await scanner.scan(catalog, onCategory: { _ in })
        return Dictionary(uniqueKeysWithValues: results.map { ($0.category.id, $0) })
    }

    private func names(_ scan: CategoryScan?) -> [String] {
        (scan?.items ?? []).map { $0.url.lastPathComponent }.sorted()
    }

    private func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-days * day)], ofItemAtPath: url.path)
    }

    private func mover(_ sb: TestSandbox, _ options: ScanOptions) -> (TrashMover, URL) {
        let trash = sb.root.appending(path: "trash", directoryHint: .isDirectory)
        return (TrashMover(
            backend: DirectoryTrashBackend(directory: trash),
            protectedPaths: options.protectedPaths(environment: sb.environment)), trash)
    }

    // MARK: recency

    @Test func recentlyChangedItemsAreSkipped() async throws {
        let sb = try TestSandbox()
        let fresh = try sb.file("home/Library/Caches/com.fresh/a", bytes: 1024)
        let old = try sb.file("home/Library/Caches/com.old/a", bytes: 1024)
        let edge = try sb.file("home/Library/Caches/com.edge/a", bytes: 1024)
        try age(fresh.deletingLastPathComponent(), days: 1)
        try age(old.deletingLastPathComponent(), days: 30)
        try age(edge.deletingLastPathComponent(), days: 7)   // exactly N days: old enough

        let off = await scan(sb, options: ScanOptions())
        #expect(names(off[.userCaches]) == ["com.edge", "com.fresh", "com.old"])
        let on = await scan(sb, options: ScanOptions(skipChangedWithinDays: 7))
        #expect(names(on[.userCaches]) == ["com.edge", "com.old"])
        let zero = await scan(sb, options: ScanOptions(skipChangedWithinDays: 0))
        #expect(names(zero[.userCaches]).count == 3)
    }

    @Test func futureDatedItemsCountAsRecentAndTrashIsExempt() async throws {
        let sb = try TestSandbox()
        let future = try sb.file("home/Library/Caches/com.future/a")
        try age(future.deletingLastPathComponent(), days: -3)
        let trashed = try sb.file("home/.Trash/new.bin", bytes: 4096)
        try age(trashed, days: 0)
        let r = await scan(sb, options: ScanOptions(skipChangedWithinDays: 7))
        #expect(names(r[.userCaches]).isEmpty)
        #expect(names(r[.trash]) == ["new.bin"])
    }

    // MARK: exclusions

    @Test func excludedFolderIsNeverScannedNorMoved() async throws {
        let sb = try TestSandbox()
        let keep = try sb.file("home/Library/Caches/com.keep/a", bytes: 1024).deletingLastPathComponent()
        try sb.file("home/Library/Caches/com.other/a", bytes: 1024)
        let nested = try sb.file("home/Library/Caches/Wrapper/keep/b", bytes: 1024).deletingLastPathComponent()
        try sb.file("home/Library/Caches/Plain/c", bytes: 1024)
        let options = ScanOptions(exclusions: [keep.path, nested.path])

        let r = await scan(sb, options: options)
        // Excluded itself and the ancestor that contains an exclusion both disappear; nothing else does.
        #expect(names(r[.userCaches]) == ["Plain", "com.other"])

        let caches = sb.environment.userLibrary.appending(path: "Caches")
        let (mover, trash) = mover(sb, options)
        for url in [keep, keep.appending(path: "a"), nested.deletingLastPathComponent(), nested] {
            let outcome = mover.moveToTrash(url, allowedRoots: [caches])
            guard case .skipped = outcome else { Issue.record("expected skip for \(url.path), got \(outcome)"); continue }
        }
        #expect(mover.moveToTrash(keep, allowedRoots: [caches]) == .skipped(reason: "excluded in Settings"))
        #expect(mover.moveToTrash(keep.appending(path: "a"), allowedRoots: [caches])
                == .skipped(reason: "excluded in Settings"))
        #expect(mover.moveToTrash(nested.deletingLastPathComponent(), allowedRoots: [caches])
                == .skipped(reason: "contains a folder excluded in Settings"))
        #expect(FileManager.default.fileExists(atPath: keep.appending(path: "a").path))
        #expect(FileManager.default.fileExists(atPath: nested.appending(path: "b").path))
        #expect(!FileManager.default.fileExists(atPath: trash.path))

        // A sibling is still movable.
        let other = caches.appending(path: "com.other")
        guard case .movedToTrash = mover.moveToTrash(other, allowedRoots: [caches]) else {
            Issue.record("sibling should move"); return
        }
    }

    @Test func exclusionsNormalizeAndIgnoreJunk() throws {
        let sb = try TestSandbox()
        let env = sb.environment
        let options = ScanOptions(exclusions: ["", "   ", "relative/path", "~someoneelse/x", "~/Library/Caches/Foo/", "/tmp/../tmp/x"])
        let urls = options.exclusionURLs(home: env.home).map { $0.path(percentEncoded: false) }
        #expect(urls == [env.home.appending(path: "Library/Caches/Foo").standardizedFileURL.path, "/tmp/x"])
        // Garbage-only options protect nothing and don't crash.
        let guardPaths = ScanOptions(exclusions: ["", "nope"]).protectedPaths(environment: env)
        let caches = env.userLibrary.appending(path: "Caches")
        #expect(guardPaths.verdict(for: caches.appending(path: "x"), allowedRoots: [caches]) == .allowed)
    }

    @Test func exclusionOnProtectedLocationKeepsProtectedReason() throws {
        let sb = try TestSandbox()
        let env = sb.environment
        let docs = env.home.appending(path: "Documents")
        let p = ProtectedPaths(environment: env, extraDenied: [docs, env.userLibrary])
        #expect(p.verdict(for: docs.appending(path: "a"), allowedRoots: [docs]) == .denied(reason: "protected location"))
        #expect(p.verdict(for: env.userLibrary, allowedRoots: [env.home]) == .denied(reason: "protected location"))
    }

    @Test func exclusionMatchingUsesComponentsFoldsAndSymlinks() throws {
        let sb = try TestSandbox()
        let caches = try sb.directory("home/Library/Caches")
        try sb.file("home/Library/Caches/Foo/keep/x")
        try sb.file("home/Library/Caches/Foobar/x")
        let p = ProtectedPaths(environment: sb.environment, extraDenied: [caches.appending(path: "Foo/keep")])
        // Not a string prefix match.
        #expect(p.verdict(for: caches.appending(path: "Foobar"), allowedRoots: [caches]) == .allowed)
        // Case-insensitive file systems.
        #expect(p.verdict(for: caches.appending(path: "FOO/KEEP/x"), allowedRoots: [caches])
                == .denied(reason: "excluded in Settings"))
        // A symlinked parent to the excluded folder is resolved.
        let link = sb.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: caches.appending(path: "Foo"))
        #expect(p.verdict(for: link.appending(path: "keep/x"), allowedRoots: [caches])
                == .denied(reason: "excluded in Settings"))
        // The exclusion given through a symlink protects the real place.
        let q = ProtectedPaths(environment: sb.environment, extraDenied: [link.appending(path: "keep")])
        #expect(q.verdict(for: caches.appending(path: "Foo"), allowedRoots: [caches])
                == .denied(reason: "contains a folder excluded in Settings"))
    }

    // MARK: external trash

    @Test func externalTrashToggle() async throws {
        let sb = try TestSandbox()
        let uid = String(sb.environment.userID)
        try sb.file("home/.Trash/a.bin", bytes: 4096)
        try sb.file("Volumes/Ext/.Trashes/\(uid)/f.bin", bytes: 8192)

        let with = await scan(sb, options: ScanOptions())
        #expect(names(with[.trash]) == ["a.bin", "f.bin"])
        let without = await scan(sb, options: ScanOptions(includeExternalTrash: false))
        #expect(names(without[.trash]) == ["a.bin"])

        func inspector(_ include: Bool) -> TrashInspector {
            TrashInspector(
                environment: sb.environment, journal: RunJournal(directory: sb.environment.historyDirectory),
                logger: RunLogger(directory: sb.environment.logsDirectory), sizer: DirectorySizer(),
                includeExternalVolumes: include)
        }
        #expect(inspector(true).trashLocations().count == 2)
        #expect(inspector(false).trashLocations().count == 1)
        #expect(inspector(false).size().fileCount == 1)

        let record = inspector(false).emptyTrash()
        #expect(record.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: sb.root.appending(path: "Volumes/Ext/.Trashes/\(uid)/f.bin").path))
        #expect(!FileManager.default.fileExists(atPath: sb.root.appending(path: "home/.Trash/a.bin").path))
    }

    @Test func optionsRoundTripThroughCodable() throws {
        let o = ScanOptions(skipChangedWithinDays: 3, includeExternalTrash: false, exclusions: ["/a"])
        #expect(try JSONDecoder().decode(ScanOptions.self, from: JSONEncoder().encode(o)) == o)
        #expect(ScanOptions() == ScanOptions(skipChangedWithinDays: nil, includeExternalTrash: true, exclusions: []))
    }

    // MARK: fix round 1

    @Test func exclusionsNeverHideTrashContents() async throws {
        let sb = try TestSandbox()
        try sb.file("home/.Trash/keep/a.bin", bytes: 4096)
        try sb.file("home/.Trash/b.bin", bytes: 4096)
        let inspector = TrashInspector(
            environment: sb.environment, journal: RunJournal(directory: sb.environment.historyDirectory),
            logger: RunLogger(directory: sb.environment.logsDirectory), sizer: DirectorySizer())
        let expected = inspector.contents().items.map { $0.url.lastPathComponent }.sorted()
        #expect(expected == ["b.bin", "keep"])
        for exclusion in [sb.environment.userTrash.appending(path: "keep").path, "~", sb.environment.userTrash.path] {
            let r = await scan(sb, options: ScanOptions(skipChangedWithinDays: 7, exclusions: [exclusion]))
            #expect(names(r[.trash]) == expected)
        }
    }

    @Test func firmlinkFormOfAnExclusionProtectsTheRealPath() throws {
        let sb = try TestSandbox()
        let caches = try sb.directory("home/Library/Caches")
        let keep = try sb.directory("home/Library/Caches/Keep")
        let real = keep.resolvingSymlinksInPath().path(percentEncoded: false)
        let firm = URL(filePath: "/System/Volumes/Data" + real)
        let p = ProtectedPaths(environment: sb.environment, extraDenied: [firm])
        #expect(p.verdict(for: keep.appending(path: "x"), allowedRoots: [caches]) == .denied(reason: "excluded in Settings"))
        #expect(p.verdict(for: caches.appending(path: "Other"), allowedRoots: [caches]) == .allowed)
        #expect(ProtectedPaths.withoutDataVolumePrefix(["System", "Volumes", "Data", "Users", "u"]) == ["Users", "u"])
        #expect(ProtectedPaths.withoutDataVolumePrefix(["System", "Volumes", "Data"]) == nil)
        #expect(ProtectedPaths.withoutDataVolumePrefix(["Users", "u"]) == nil)
    }

    @Test func normalizerReportsWhyEntriesAreIgnored() {
        let home = URL(filePath: "/Users/me")
        let r = ScanOptions.normalizeExclusions(
            ["", "  ", "rel/path", "file:///tmp/x", "~bob/x", "~", "~/a/", "/x/../y"], home: home)
        #expect(r.accepted.map(\.path) == ["/Users/me", "/Users/me/a", "/y"])
        #expect(r.ignored.map(\.reason) == ["empty", "empty", "not an absolute path", "file URL not supported", "unknown user"])
        #expect(r.ignored.map(\.entry) == ["", "  ", "rel/path", "file:///tmp/x", "~bob/x"])
    }

    @Test func partialSettingsDecodeWithDefaults() throws {
        let empty = try JSONDecoder().decode(ScanOptions.self, from: Data("{}".utf8))
        #expect(empty == ScanOptions())
        let partial = try JSONDecoder().decode(ScanOptions.self, from: Data(#"{"exclusions":["/a"]}"#.utf8))
        #expect(partial == ScanOptions(exclusions: ["/a"]))
    }
}

@Suite struct LiveExclusionsTests {
    /// Settings changes exclusions while Dustling runs: the mover built at launch follows them.
    @Test func exclusionAddedInSettingsTakesEffectWithoutRestart() throws {
        let sb = try TestSandbox()
        let keep = try sb.file("home/Library/Caches/com.keep/a", bytes: 1024).deletingLastPathComponent()
        let caches = sb.environment.userLibrary.appending(path: "Caches")
        let live = LiveExclusions([])
        let paths = ProtectedPaths(environment: sb.environment, liveExclusions: live)
        #expect(paths.verdict(for: keep, allowedRoots: [caches]) == .allowed)

        live.set([keep])
        #expect(paths.verdict(for: keep, allowedRoots: [caches]) == .denied(reason: "excluded in Settings"))
        #expect(paths.exclusionReason(for: keep.appending(path: "a")) == "excluded in Settings")

        live.set([])
        #expect(paths.verdict(for: keep, allowedRoots: [caches]) == .allowed)
    }

    /// Fixed exclusions (`extraDenied`) still apply next to the live ones.
    @Test func fixedAndLiveExclusionsCombine() throws {
        let sb = try TestSandbox()
        let one = try sb.file("home/Library/Caches/one/a", bytes: 1).deletingLastPathComponent()
        let two = try sb.file("home/Library/Caches/two/a", bytes: 1).deletingLastPathComponent()
        let caches = sb.environment.userLibrary.appending(path: "Caches")
        let paths = ProtectedPaths(environment: sb.environment, extraDenied: [one], liveExclusions: LiveExclusions([two]))
        #expect(paths.verdict(for: one, allowedRoots: [caches]) == .denied(reason: "excluded in Settings"))
        #expect(paths.verdict(for: two, allowedRoots: [caches]) == .denied(reason: "excluded in Settings"))
    }

    /// Without Full Disk Access, an exclusion inside a consent folder is keyed by its text: setting it
    /// never resolves (and so never reads) anything inside that folder.
    @Test func exclusionsInConsentFoldersAreKeyedTextually() throws {
        let home = URL(filePath: "/Users/tester")
        let downloads = home.appending(path: "Downloads")
        let containers = home.appending(path: "Library/Containers")
        var asked: [String] = []
        let keys = ProtectedPaths.keys(
            for: [downloads.appending(path: "keep"), containers.appending(path: "com.x/Data"), downloads],
            textualUnder: [downloads, containers],
            realpath: { asked.append($0); return nil })
        // Only the consent folders themselves are resolved, never anything inside them.
        #expect(!asked.contains { $0.hasPrefix(downloads.path + "/") || $0.hasPrefix(containers.path + "/") })
        #expect(keys.count == 6)
        #expect(keys[0].suffix(2) == ["downloads", "keep"])

        // Outside a consent folder, entries are still resolved.
        _ = ProtectedPaths.keys(for: [home.appending(path: "Library/Caches/x")], textualUnder: [downloads],
                                realpath: { asked.append($0); return nil })
        #expect(!asked.isEmpty)
    }

    @Test func consentFolderMatchIgnoresCase() throws {
        let home = URL(filePath: "/Users/tester")
        let downloads = home.appending(path: "Downloads")
        var asked: [String] = []
        // Typed by hand in a different case: still inside Downloads, so nothing inside it is resolved.
        let keys = ProtectedPaths.keys(
            for: [URL(filePath: "/Users/tester/downloads/x"), URL(filePath: "/USERS/Tester/DOWNLOADS")],
            textualUnder: [downloads],
            realpath: { asked.append($0); return nil })
        #expect(!asked.contains { $0.lowercased().hasPrefix(downloads.path.lowercased() + "/") })
        #expect(!asked.contains { $0.lowercased() == "/users/tester/downloads/x" })
        #expect(keys.count == 4)
        #expect(keys[0].suffix(2) == ["downloads", "x"])
    }

    @Test func textualExclusionStillProtects() throws {
        let sb = try TestSandbox()
        let item = try sb.file("home/Library/Caches/com.keep/a", bytes: 1).deletingLastPathComponent()
        let caches = sb.environment.userLibrary.appending(path: "Caches")
        let live = LiveExclusions([item], textualUnder: [caches])
        let paths = ProtectedPaths(environment: sb.environment, liveExclusions: live)
        // The temp folder sits behind /var -> /private/var: the key from the resolved folder still matches.
        #expect(paths.verdict(for: item, allowedRoots: [caches]) == .denied(reason: "excluded in Settings"))
    }
}
