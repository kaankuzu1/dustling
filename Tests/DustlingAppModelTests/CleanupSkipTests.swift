import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

struct CleanupSkipTests {
    private let environment = SystemEnvironment(
        home: URL(filePath: "/Users/tester"), applicationDirectories: [], systemLibrary: URL(filePath: "/Library"),
        volumesDirectory: URL(filePath: "/Volumes"), userID: 501)

    @Test func closedPlacesAreSkippedWholeAndPartlyOpenOnesSkipTheirContainers() {
        let catalog = JunkCatalog.standard(environment)
        let places = [
            Place(id: .userCaches, access: .readable, lockedExpansions: true),
            Place(id: .userLogs, access: .readable),
            Place(id: .mailDownloads, access: .locked),
            Place(id: .trash, access: .unreadable),
        ]
        let skip = CleanupSkip.from(places: places, catalog: catalog)
        #expect(skip.categories == [.mailDownloads, .trash])
        #expect(skip.folders.map(\.path) == ["/Users/tester/Library/Containers"])
    }

    @Test func noPlacesCheckedMeansNothingSkipped() {
        #expect(CleanupSkip.from(places: [], catalog: JunkCatalog.standard(environment)) == .none)
    }
}
