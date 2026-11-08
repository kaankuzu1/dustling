import Foundation
import Testing
@testable import DustlingCore

struct ScanTotalsTests {
    private func category(_ id: JunkCategoryID, _ env: SystemEnvironment) throws -> JunkCategory {
        try #require(JunkCatalog.standard(env).first { $0.id == id })
    }

    private func scan(
        _ category: JunkCategory, _ items: [(String, UInt64, String?)], issues: [ScanIssue] = []
    ) -> CategoryScan {
        let made = items.map {
            JunkItem(url: URL(filePath: "/x/\($0.0)"), bytes: $0.1, category: category.id, inUseByBundleID: $0.2)
        }
        return CategoryScan(category: category, items: made, bytes: made.reduce(0) { $0 + $1.bytes }, issues: issues)
    }

    @Test func categoryTotalTellsCompleteFromPartialFromCouldntScan() throws {
        let env = try TestSandbox().environment
        let caches = try category(.userCaches, env)
        let complete = scan(caches, [("a", 10, nil)]).total
        #expect(complete == ScanTotal(bytes: 10, itemCount: 1, isComplete: true, needsFullDiskAccess: false))

        let partial = scan(caches, [("a", 10, nil)], issues: [.unreadable(URL(filePath: "/x/a/b"))]).total
        #expect(partial.bytes == 10 && !partial.isComplete && !partial.couldNotScan && !partial.needsFullDiskAccess)

        let blocked = scan(caches, [], issues: [.missingFullDiskAccess(URL(filePath: "/x"))]).total
        #expect(blocked.couldNotScan && blocked.needsFullDiskAccess && blocked.bytes == 0)

        let unreadable = scan(caches, [], issues: [.unreadable(URL(filePath: "/x"))]).total
        #expect(unreadable.couldNotScan && !unreadable.needsFullDiskAccess)

        let empty = scan(caches, []).total
        #expect(empty.isComplete && !empty.couldNotScan && empty.bytes == 0)
    }

    @Test func totalsAreSplitAndNeverCombined() throws {
        let env = try TestSandbox().environment
        let totals = ScanTotals([
            scan(try category(.browserCaches, env), [("Google", 100, nil), ("Firefox", 50, "org.mozilla.firefox")]),
            scan(try category(.userLogs, env), [("x", 7, nil)]),
            scan(try category(.systemCachesAndLogs, env), [("sys", 300, nil)]),
            scan(try category(.trash, env), [("t", 1_000, nil)]),
            scan(try category(.oldInstallers, env), [("a.dmg", 20, nil)]),
            scan(try category(.iosBackups, env), [("b", 30, nil)]),
        ])
        #expect(totals.cleanableByDefault == ScanTotal(bytes: 107, itemCount: 3, isComplete: true, needsFullDiskAccess: false))
        #expect(totals.skippedInUse == 50)
        #expect(totals.review == ScanTotal(bytes: 50, itemCount: 2, isComplete: true, needsFullDiskAccess: false))
        #expect(totals.needsAdmin == ScanTotal(bytes: 300, itemCount: 1, isComplete: true, needsFullDiskAccess: false))
        #expect(totals.trash == ScanTotal(bytes: 1_000, itemCount: 1, isComplete: true, needsFullDiskAccess: false))
    }

    @Test func anIncompleteCategoryMakesItsTotalALowerBound() throws {
        let env = try TestSandbox().environment
        let fda = ScanIssue.missingFullDiskAccess(URL(filePath: "/x"))
        let totals = ScanTotals([
            scan(try category(.browserCaches, env), [("Google", 100, nil)]),
            scan(try category(.userCaches, env), [], issues: [fda]),
            scan(try category(.mailDownloads, env), [], issues: [fda]),
        ])
        #expect(totals.cleanableByDefault.bytes == 100 && !totals.cleanableByDefault.isComplete)
        #expect(!totals.cleanableByDefault.couldNotScan && totals.cleanableByDefault.needsFullDiskAccess)
        #expect(totals.review.couldNotScan && totals.review.needsFullDiskAccess)
        #expect(totals.needsAdmin == ScanTotal())
    }
}
