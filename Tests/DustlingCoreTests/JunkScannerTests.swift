import Foundation
import Testing
@testable import DustlingCore

@Suite struct JunkScannerTests {
    private func scan(
        _ sandbox: TestSandbox, now: Date = .now, running: Set<String> = []
    ) async throws -> [JunkCategoryID: CategoryScan] {
        let catalog = JunkCatalog.standard(sandbox.environment, now: now)
        let scanner = JunkScanner(environment: sandbox.environment, runningBundleIDs: { running })
        let results = await scanner.scan(catalog, onCategory: { _ in })
        return Dictionary(uniqueKeysWithValues: results.map { ($0.category.id, $0) })
    }

    private func names(_ scan: CategoryScan?) -> [String] {
        (scan?.items ?? []).map { $0.url.lastPathComponent }.sorted()
    }

    @Test func browserCacheIsNotDoubleCounted() async throws {
        let sb = try TestSandbox()
        try sb.file("home/Library/Caches/Google/x", bytes: 1024)
        try sb.file("home/Library/Caches/com.foo/y", bytes: 1024)
        let r = try await scan(sb)
        #expect(names(r[.browserCaches]) == ["Google"])
        #expect(names(r[.userCaches]) == ["com.foo"])
    }

    @Test func selectionsMatchSpec() throws {
        let sb = try TestSandbox()
        let cats = Dictionary(uniqueKeysWithValues:
            JunkCatalog.standard(sb.environment).map { ($0.id, $0) })
        #expect(cats[.trash]?.selection == .emptyTrashOnly)
        #expect(cats[.oldInstallers]?.selection == .review)
        #expect(cats[.userCaches]?.selection == .preselected)
        #expect(cats[.systemCachesAndLogs]?.requiresAdmin == true)
        #expect(JunkCatalog.standard(sb.environment).map(\.id) == JunkCategoryID.allCases)
    }

    @Test func systemCachesAreNeverCleanedByDefault() throws {
        let sb = try TestSandbox()
        let catalog = JunkCatalog.standard(sb.environment)
        // What a clean picks without being told: the same in the app (ticked tiles) and the CLI.
        #expect(catalog.filter(\.isSelectedByDefault).map(\.id)
            == [.browserCaches, .xcodeJunk, .packageManagerCaches, .userCaches, .userLogs])
        let scans = catalog.map { CategoryScan(category: $0, items: [], bytes: 0, issues: []) }
        // `dustling-cli clean`: System caches and logs only when named (`--include systemCachesAndLogs`),
        // review categories too; the Trash never.
        #expect(JunkCatalog.cleanChoice(scans, including: []).map(\.category.id)
            == [.browserCaches, .xcodeJunk, .packageManagerCaches, .userCaches, .userLogs])
        #expect(JunkCatalog.cleanChoice(scans, including: [.systemCachesAndLogs, .iosBackups, .trash])
            .map(\.category.id)
            == [.browserCaches, .xcodeJunk, .packageManagerCaches, .userCaches, .userLogs, .systemCachesAndLogs,
                .iosBackups])
    }

    @Test func unreadableRootIsReportedNotZero() async throws {
        let sb = try TestSandbox()
        let caches = try sb.directory("home/Library/Caches")
        try sb.file("home/Library/Caches/com.foo/y")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: caches.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: caches.path) }
        let r = try await scan(sb)
        let issues = r[.userCaches]?.issues ?? []
        #expect(issues.count == 1)
        guard case .missingFullDiskAccess(let url)? = issues.first else { Issue.record("wrong issue"); return }
        #expect(url.path == caches.path)
        #expect(r[.userCaches]?.items.isEmpty == true)
    }

    @Test func largeOldDownloadsUsesThresholds() async throws {
        let sb = try TestSandbox()
        let big = try sb.file("home/Downloads/big.bin", bytes: 0)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 600 * 1024 * 1024)
        try handle.close()
        let old = try sb.file("home/Downloads/old.txt", bytes: 10)
        try sb.file("home/Downloads/recent.txt", bytes: 10)
        // Access dates cannot be set via FileManager; use utimes (atime = 100 days ago).
        let past = Date().addingTimeInterval(-100 * 86_400)
        var times = [
            timeval(tv_sec: Int(past.timeIntervalSince1970), tv_usec: 0),
            timeval(tv_sec: Int(Date().timeIntervalSince1970), tv_usec: 0),
        ]
        #expect(utimes(old.path, &times) == 0)
        let r = try await scan(sb)
        #expect(names(r[.largeOldDownloads]) == ["big.bin", "old.txt"])
    }

    @Test func oldInstallersTakeDmgAndPkgFirst() async throws {
        let sb = try TestSandbox()
        try sb.file("home/Downloads/app.dmg", bytes: 10)
        try sb.file("home/Downloads/x.txt", bytes: 10)
        let r = try await scan(sb)
        #expect(names(r[.oldInstallers]) == ["app.dmg"])
        #expect(!names(r[.largeOldDownloads]).contains("app.dmg"))
    }

    @Test func userLogsExcludeDustlingAndTrashRootsCovered() async throws {
        let sb = try TestSandbox()
        try sb.file("home/Library/Logs/Dustling/a.log")
        try sb.file("home/Library/Logs/other/b.log")
        try sb.file("home/.Trash/t.txt")
        let uid = sb.environment.userID
        try sb.file("Volumes/Disk/.Trashes/\(uid)/v.txt")
        try sb.file("home/Library/Containers/com.x/Data/Library/Caches/c/f")
        let r = try await scan(sb)
        #expect(names(r[.userLogs]) == ["other"])
        #expect(names(r[.trash]) == ["t.txt", "v.txt"])
        #expect(names(r[.userCaches]) == ["c"])
    }

    @Test func marksCachesOfRunningApps() async throws {
        let sb = try TestSandbox()
        try sb.file("home/Library/Caches/com.foo/y")
        try sb.file("home/Library/Caches/com.bar/y")
        let r = try await scan(sb, running: ["com.foo"])
        let items = Dictionary(uniqueKeysWithValues:
            (r[.userCaches]?.items ?? []).map { ($0.url.lastPathComponent, $0.inUseByBundleID) })
        #expect(items["com.foo"] == "com.foo")
        #expect(items["com.bar"] == .some(nil))
    }

    @Test func unreadableItemContentsBecomeIssues() async throws {
        let sb = try TestSandbox()
        let locked = try sb.directory("home/Library/Caches/com.foo/locked")
        try sb.file("home/Library/Caches/com.foo/locked/z")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let r = try await scan(sb)
        #expect(names(r[.userCaches]) == ["com.foo"])
        let paths = (r[.userCaches]?.issues ?? []).compactMap { issue -> String? in
            if case .unreadable(let u) = issue { return u.path }
            return nil
        }
        #expect(paths.contains { $0.hasSuffix("/home/Library/Caches/com.foo/locked") })
    }

    @Test func scanIsCancellable() async throws {
        let sb = try TestSandbox()
        let catalog = JunkCatalog.standard(sb.environment)
        let scanner = JunkScanner(environment: sb.environment, runningBundleIDs: { [] })
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await scanner.scan(catalog, onCategory: { _ in })
        }
        task.cancel()
        // Cancelled before any category started: no throw, and the first category is marked stopped, empty.
        let result = await task.value
        #expect(result.count == 1)
        #expect(result[0].stopped && result[0].items.isEmpty)
    }

    // MARK: - Progress and mid-folder stop

    /// Thread-safe collector for @Sendable callbacks.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    }

    private func makeFiles(_ count: Int, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            #expect(FileManager.default.createFile(atPath: dir.appending(path: "f\(i)").path, contents: nil))
        }
    }

    private func category(_ id: JunkCategoryID, root: URL) -> JunkCategory {
        JunkCategory(id: id, title: "t", selection: .preselected, requiresAdmin: false, roots: [root])
    }

    @Test func progressIsThrottledAndMonotonic() async throws {
        let sb = try TestSandbox()
        var cats: [JunkCategory] = []
        for (i, id) in [JunkCategoryID.userCaches, .userLogs].enumerated() {
            let root = sb.root.appending(path: "r\(i)", directoryHint: .isDirectory)
            for n in 0..<80 { try sb.file("r\(i)/f\(n)", bytes: 10) }
            // Slow measurement (about 5 ms per item) so each category runs well past 100 ms.
            cats.append(JunkCategory(
                id: id, title: "t", selection: .preselected, requiresAdmin: false, roots: [root],
                measuredFilter: { _, _ in Thread.sleep(forTimeInterval: 0.005); return true }))
        }
        let scanner = JunkScanner(environment: sb.environment, runningBundleIDs: { [] })
        let events = Box<[(ScanProgress, ContinuousClock.Instant)]>([])
        let started = ContinuousClock.now
        _ = await scanner.scan(cats, onCategory: { _ in }, onProgress: { p in
            events.with { $0.append((p, .now)) }   // timestamp taken inside the callback
        })
        let elapsed = started.duration(to: .now)
        let all = events.with { $0 }
        var sameCategoryGaps = 0
        for (a, b) in zip(all, all.dropFirst()) {
            #expect(b.0.bytesFound >= a.0.bytesFound)
            #expect(b.0.categoriesDone >= a.0.categoriesDone)
            if a.0.categoriesDone == b.0.categoriesDone {
                sameCategoryGaps += 1
                #expect(a.1.duration(to: b.1) >= .milliseconds(90))
            }
        }
        // The throttle was really exercised: several events inside the categories, not just one each.
        #expect(sameCategoryGaps >= 2)
        #expect(all.allSatisfy { $0.0.categoriesTotal == 2 })
        #expect(all.last?.0.categoriesDone == 2)
        // Loose upper bound: far fewer events than the 160 items measured.
        let ms = Int(elapsed / .milliseconds(1))
        #expect(all.count <= ms / 100 + 1 + 2 + 2)
    }

    @Test func filteredCategoryNeverInflatesLiveCounter() async throws {
        let sb = try TestSandbox()
        let rejectRoot = sb.root.appending(path: "rej", directoryHint: .isDirectory)
        for n in 0..<20 { try sb.file("rej/f\(n)", bytes: 50_000) }
        let keepRoot = sb.root.appending(path: "keep", directoryHint: .isDirectory)
        for n in 0..<5 { try sb.file("keep/f\(n)", bytes: 50_000) }
        let rejecting = JunkCategory(
            id: .userCaches, title: "t", selection: .preselected, requiresAdmin: false, roots: [rejectRoot],
            measuredFilter: { _, _ in false })
        var scanner = JunkScanner(environment: sb.environment, runningBundleIDs: { [] })
        scanner.progressInterval = .zero
        let events = Box<[ScanProgress]>([])
        let results = await scanner.scan(
            [rejecting, category(.userLogs, root: keepRoot)], onCategory: { _ in },
            onProgress: { p in events.with { $0.append(p) } })
        let all = events.with { $0 }
        #expect(results[0].items.isEmpty)
        let duringRejecting = all.filter { $0.categoriesDone == 0 }
        #expect(!duringRejecting.isEmpty)
        #expect(duringRejecting.allSatisfy { $0.bytesFound == 0 })
        #expect(all.last?.bytesFound == results.reduce(0) { $0 + $1.bytes })
        #expect(results[1].bytes > 0)
    }

    @Test func cancelBetweenCategoriesMarksNextOneStopped() async throws {
        let sb = try TestSandbox()
        var cats: [JunkCategory] = []
        for (i, id) in [JunkCategoryID.userCaches, .userLogs, .browserCaches].enumerated() {
            try sb.file("c\(i)/a", bytes: 10)
            cats.append(category(id, root: sb.root.appending(path: "c\(i)", directoryHint: .isDirectory)))
        }
        let scanner = JunkScanner(environment: sb.environment, runningBundleIDs: { [] })
        let seen = Box<[CategoryScan]>([])
        let canceller = LateCanceller()
        let task = Task {
            await scanner.scan(cats, onCategory: { s in seen.with { $0.append(s) } }, onProgress: { p in
                if p.categoriesDone == 1 { canceller.cancelTask() }
            })
        }
        canceller.attach(task)
        let result = await task.value
        #expect(result.count == 2)
        #expect(result[0].stopped == false)
        #expect(result[1].category.id == .userLogs)
        #expect(result[1].stopped)
        #expect(result[1].items.isEmpty && result[1].issues.isEmpty)
        #expect(seen.with { $0.count } == 2)
        #expect(ScanTotals(result).cleanableByDefault.isComplete == false)
    }

    @Test func stopMarksPartialCategory() async throws {
        let sb = try TestSandbox()
        let first = sb.root.appending(path: "first", directoryHint: .isDirectory)
        try sb.file("first/a", bytes: 10)
        let second = sb.root.appending(path: "second", directoryHint: .isDirectory)
        try makeFiles(3_000, in: second.appending(path: "big", directoryHint: .isDirectory))
        try sb.file("second/aaa-small", bytes: 10)   // sorts before "big": measured before the cancel
        let third = sb.root.appending(path: "third", directoryHint: .isDirectory)
        try sb.file("third/c", bytes: 10)
        // Deterministic stop: cancel right after the small item is accepted, before the big one is measured.
        let canceller = LateCanceller()
        let secondCat = JunkCategory(
            id: .userLogs, title: "t", selection: .preselected, requiresAdmin: false, roots: [second],
            measuredFilter: { url, _ in
                if url.lastPathComponent == "aaa-small" { canceller.cancelTask() }
                return true
            })
        let cats = [category(.userCaches, root: first), secondCat, category(.browserCaches, root: third)]
        let scanner = JunkScanner(environment: sb.environment, runningBundleIDs: { [] })
        let seen = Box<[CategoryScan]>([])
        let task = Task {
            await scanner.scan(cats, onCategory: { s in seen.with { $0.append(s) } }, onProgress: { _ in })
        }
        canceller.attach(task)
        let result = await task.value
        #expect(result.count == 2)                       // third never started
        #expect(result[0].stopped == false)
        #expect(names(result[0]) == ["a"])
        #expect(result[1].category.id == .userLogs)
        #expect(result[1].stopped == true)
        // Only what was fully measured: the small item, never the half-measured big folder.
        #expect(names(result[1]) == ["aaa-small"])
        #expect(result[1].bytes == result[1].items.reduce(0) { $0 + $1.bytes })
        #expect(result[1].total.isComplete == false)     // shown as "at least", never as a full number
        #expect(seen.with { $0.count } == 2)
    }

    @Test func cancelDuringHugeDirectoryStopsQuickly() async throws {
        let sb = try TestSandbox()
        let root = sb.root.appending(path: "huge", directoryHint: .isDirectory)
        try sb.file("huge/aaa-small", bytes: 10)
        try makeFiles(20_000, in: root.appending(path: "big", directoryHint: .isDirectory))
        var scanner = JunkScanner(environment: sb.environment, runningBundleIDs: { [] })
        scanner.progressInterval = .zero   // every enumeration tick reaches the callback
        let cancelledAt = Box<ContinuousClock.Instant?>(nil)
        let insideBig = Box<Int>(0)
        let canceller = LateCanceller()
        let task = Task {
            await scanner.scan([category(.userCaches, root: root)], onCategory: { _ in }, onProgress: { p in
                // Events with a path inside big/ come from the enumeration itself; stop at the third
                // (about 257 entries in), well before the 20 000th.
                guard p.currentPath.path.contains("/big/") else { return }
                if insideBig.with({ $0 += 1; return $0 }) == 3 {
                    cancelledAt.with { $0 = .now }
                    canceller.cancelTask()
                }
            })
        }
        canceller.attach(task)
        let result = await task.value
        let returned = ContinuousClock.now
        let start = try #require(cancelledAt.with { $0 })
        #expect(start.duration(to: returned) < .seconds(1))
        #expect(result.count == 1)
        #expect(result[0].stopped)
        #expect(names(result[0]) == ["aaa-small"])   // the half-measured big folder is dropped
    }

    private func fdaPaths(_ scan: CategoryScan?) -> [String] {
        (scan?.issues ?? []).compactMap { if case .missingFullDiskAccess(let u) = $0 { u.path } else { nil } }
    }

    @Test func protectedAncestorOfExpandedRootIsReported() async throws {
        let sb = try TestSandbox()
        let containers = try sb.directory("home/Library/Containers")
        try sb.file("home/Library/Containers/com.x/Data/Library/Caches/c/f")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: containers.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: containers.path) }
        let r = try await scan(sb)
        #expect(fdaPaths(r[.userCaches]).contains { $0.hasSuffix("/home/Library/Containers") })
        // Mail Downloads sits below the protected directory: denied, not "missing".
        #expect(fdaPaths(r[.mailDownloads]).contains { $0.hasSuffix("Mail Downloads") })
    }

    @Test func nonexistentRootsProduceNoIssues() async throws {
        let sb = try TestSandbox()
        let r = try await scan(sb)
        for (_, s) in r { #expect(s.issues.isEmpty) }
    }

    @Test func rootThatIsAFileIsUnreadableNotFullDiskAccess() async throws {
        let sb = try TestSandbox()
        let root = try sb.file("home/Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        let r = try await scan(sb)
        let issues = r[.mailDownloads]?.issues ?? []
        #expect(issues.count == 1)
        guard case .unreadable(let u)? = issues.first else { Issue.record("expected unreadable"); return }
        #expect(u.path == root.path)
        #expect(fdaPaths(r[.mailDownloads]).isEmpty)
    }

    @Test func oldDirectoryInDownloadsQualifiesViaMeasuredFilter() async throws {
        let sb = try TestSandbox()
        let dir = try sb.directory("home/Downloads/olddir")
        try sb.file("home/Downloads/olddir/f", bytes: 10)
        try sb.directory("home/Downloads/newdir")
        try sb.file("home/Downloads/newdir/f", bytes: 10)
        let past = Date().addingTimeInterval(-100 * 86_400)
        var times = [timeval(tv_sec: Int(past.timeIntervalSince1970), tv_usec: 0)] 
        times.append(times[0])
        #expect(utimes(dir.path, &times) == 0)
        let catalog = JunkCatalog.standard(sb.environment).filter { $0.id == .largeOldDownloads }
        let scanner = JunkScanner(environment: sb.environment, runningBundleIDs: { [] })
        let out = await scanner.scan(catalog, onCategory: { _ in })
        #expect(names(out.first) == ["olddir"])
    }

    @Test func attributeReadFailureIsReportedAsUnreadable() async throws {
        let sb = try TestSandbox()
        try sb.file("home/Downloads/a.txt")
        struct Boom: Error {}
        let cat = JunkCategory(
            id: .largeOldDownloads, title: "t", selection: .review, requiresAdmin: false,
            roots: [sb.environment.home.appending(path: "Downloads")],
            measuredFilter: { _, _ in throw Boom() })
        let scanner = JunkScanner(environment: sb.environment, runningBundleIDs: { [] })
        let out = await scanner.scan([cat], onCategory: { _ in })
        #expect(out[0].items.isEmpty)
        #expect(out[0].issues.count == 1)
        guard case .unreadable(let u)? = out[0].issues.first else { Issue.record("expected unreadable"); return }
        #expect(u.lastPathComponent == "a.txt")
    }
    // MARK: - Declared roots (moved from the CLI, Important #3)

    @Test func declaredRootsAreFixedRootsAndTheirExpansions() throws {
        let sb = try TestSandbox()
        let cats = Dictionary(uniqueKeysWithValues: JunkCatalog.standard(sb.environment).map { ($0.id, $0) })
        let userCaches = try #require(cats[.userCaches])
        let lib = sb.environment.userLibrary
        #expect(userCaches.isDeclaredRoot(lib.appending(path: "Caches")))
        #expect(userCaches.isDeclaredRoot(lib.appending(path: "Caches/", directoryHint: .isDirectory)))
        #expect(userCaches.isDeclaredRoot(lib.appending(path: "Containers/com.x/Data/Library/Caches")))
        #expect(!userCaches.isDeclaredRoot(lib.appending(path: "Containers/com.x/Data/Library")))
        #expect(!userCaches.isDeclaredRoot(lib.appending(path: "Containers/a/b/Data/Library/Caches")))
        #expect(!userCaches.isDeclaredRoot(lib.appending(path: "Containers/Data/Library/Caches")))
        #expect(!userCaches.isDeclaredRoot(lib.appending(path: "Containers")))
        #expect(!userCaches.isDeclaredRoot(lib))
        #expect(!userCaches.isDeclaredRoot(lib.appending(path: "Caches/sub")))
        #expect(!userCaches.isDeclaredRoot(sb.environment.home.appending(path: "Downloads")))
        #expect(!userCaches.isDeclaredRoot(lib.appending(path: "Containers/x/../../Caches/Data/Library/Caches")))
        let trash = try #require(cats[.trash])
        #expect(trash.isDeclaredRoot(sb.environment.volumesDirectory.appending(path: "Ext/.Trashes/\(sb.environment.userID)")))
        #expect(!trash.isDeclaredRoot(sb.environment.volumesDirectory.appending(path: "Ext/.Trashes")))
        let downloads = try #require(cats[.oldInstallers])
        #expect(downloads.isDeclaredRoot(sb.environment.home.appending(path: "Downloads")))
        #expect(!downloads.isDeclaredRoot(lib.appending(path: "Caches")))
    }
    // MARK: - In-use owners (Important #6)

    @Test func browserCacheFoldersMapToTheirAppsBundleIDs() async throws {
        let expected = [
            "Google": "com.google.Chrome", "Firefox": "org.mozilla.firefox", "BraveSoftware": "com.brave.Browser",
            "Microsoft Edge": "com.microsoft.edgemac", "com.apple.Safari": "com.apple.Safari",
            "company.thebrowser.Browser": "company.thebrowser.Browser",
        ]
        let sb = try TestSandbox()
        for name in expected.keys { try sb.file("home/Library/Caches/\(name)/x") }
        let r = try await scan(sb, running: Set(expected.values))
        let owners = Dictionary(uniqueKeysWithValues:
            (r[.browserCaches]?.items ?? []).map { ($0.url.lastPathComponent, $0.inUseByBundleID) })
        #expect(owners.count == expected.count)
        for (name, id) in expected { #expect(owners[name] == .some(id), "\(name)") }
        let idle = try await scan(sb, running: [])
        #expect((idle[.browserCaches]?.items ?? []).allSatisfy { $0.inUseByBundleID == nil })
        // The owner is kept even when it isn't running, so in-use can be checked again later.
        let idleOwners = Dictionary(uniqueKeysWithValues:
            (idle[.browserCaches]?.items ?? []).map { ($0.url.lastPathComponent, $0.ownerBundleID) })
        for (name, id) in expected { #expect(idleOwners[name] == .some(id), "\(name)") }
    }

    @Test func containerCachesBelongToTheContainersApp() async throws {
        let sb = try TestSandbox()
        try sb.file("home/Library/Containers/com.foo.app/Data/Library/Caches/blob/y")
        try sb.file("home/Library/Containers/com.bar.app/Data/Library/Caches/other/y")
        let r = try await scan(sb, running: ["com.foo.app"])
        let owners = Dictionary(uniqueKeysWithValues:
            (r[.userCaches]?.items ?? []).map { ($0.url.lastPathComponent, $0.inUseByBundleID) })
        #expect(owners["blob"] == .some("com.foo.app"))
        #expect(owners["other"] == .some(nil))
    }
}

