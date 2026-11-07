import Foundation
import Testing
@testable import DustlingCore

@Suite struct JunkScannerTests {
    private func scan(
        _ sandbox: TestSandbox, now: Date = .now, running: Set<String> = []
    ) async throws -> [JunkCategoryID: CategoryScan] {
        let catalog = JunkCatalog.standard(sandbox.environment, now: now)
        let scanner = JunkScanner(environment: sandbox.environment, runningBundleIDs: { running })
        let results = try await scanner.scan(catalog, onCategory: { _ in })
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
            return try await scanner.scan(catalog, onCategory: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
