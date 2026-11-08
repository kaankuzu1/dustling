import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

struct PlacesModelTests {
    @Test func everyCatalogCategoryIsOnePlace() throws {
        let rig = try ModelRig()
        let places = PlaceAccessChecker.check(JunkCatalog.standard(rig.environment, options: rig.options))
        #expect(places.map(\.id) == JunkCatalog.standard(rig.environment, options: rig.options).map(\.id))
        #expect(places.count == 12)
    }

    @Test func missingRootsCountAsReadable() throws {
        // A fresh home has no Xcode, Mail or backups folders: nothing to scan there, nothing locked.
        let rig = try ModelRig()
        let places = PlaceAccessChecker.check(JunkCatalog.standard(rig.environment, options: rig.options))
        #expect(places.allSatisfy { $0.access == .readable })
    }

    @Test func deniedRootLocksItsPlaceOnly() throws {
        let rig = try ModelRig()
        let categories = JunkCatalog.standard(rig.environment, options: rig.options)
        let trash = rig.environment.userTrash.standardizedFileURL.path(percentEncoded: false)
        let places = PlaceAccessChecker.check(categories) { url in
            url.standardizedFileURL.path(percentEncoded: false) == trash ? .denied : .ok
        }
        #expect(places.filter { $0.access == .locked }.map(\.id) == [.trash])
    }

    @Test func unreadableFolderOnDiskIsLocked() throws {
        try #require(getuid() != 0, "root can open any folder")
        let rig = try ModelRig()
        let trash = rig.environment.userTrash.path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trash)
        let places = PlaceAccessChecker.check(JunkCatalog.standard(rig.environment, options: rig.options))
        #expect(places.first { $0.id == .trash }?.access == .locked)
        #expect(places.filter { $0.access == .locked }.count == 1)
    }

    @Test func expansionsProbeOnlyTheParent() throws {
        let rig = try ModelRig()
        let categories = JunkCatalog.standard(rig.environment, options: rig.options)
        var probed: [String] = []
        _ = PlaceAccessChecker.check(categories) { url in
            probed.append(url.path(percentEncoded: false))
            return .ok
        }
        let containers = rig.environment.userLibrary.appending(path: "Containers").path(percentEncoded: false)
        #expect(probed.contains(containers))
        #expect(!probed.contains { $0.hasPrefix(containers + "/") && $0.hasSuffix("Data/Library/Caches") })
    }

    @Test @MainActor func modelCountsReadableAndLocked() async {
        let model = PlacesModel(check: { _ in
            [Place(id: .browserCaches, access: .readable), Place(id: .xcodeJunk, access: .locked),
             Place(id: .trash, access: .locked), Place(id: .userLogs, access: .readable)]
        })
        #expect(model.places == nil)
        #expect(model.lockedSentence == nil)
        await model.refresh(fullDiskAccessGranted: false)
        #expect(model.total == 4)
        #expect(model.readableCount == 2)
        #expect(model.lockedPlaces.map(\.id) == [.xcodeJunk, .trash])
        #expect(model.lockedSentence == "Without it, Dustling can't see Xcode data or the Trash.")
    }

    @Test func consentFoldersAreNeverOpenedWithoutFullDiskAccess() throws {
        let rig = try ModelRig()
        let categories = JunkCatalog.standard(rig.environment, options: rig.options)
        let downloads = rig.environment.home.appending(path: "Downloads").path(percentEncoded: false)
        var probed: [String] = []
        let places = PlaceAccessChecker.check(
            categories, consentFolders: PlaceAccessChecker.consentFolders(rig.environment)
        ) { url in
            probed.append(url.path(percentEncoded: false))
            return .ok
        }
        #expect(!probed.contains { $0.hasPrefix(downloads) })
        #expect(places.filter { $0.access == .locked }.map(\.id) == [.oldInstallers, .largeOldDownloads])
    }

    @Test func consentFoldersAreProbedWithFullDiskAccess() throws {
        let rig = try ModelRig()
        let categories = JunkCatalog.standard(rig.environment, options: rig.options)
        var probed: [String] = []
        let places = PlaceAccessChecker.check(
            categories, consentFolders: PlaceAccessChecker.consentFolders(rig.environment),
            fullDiskAccessGranted: true
        ) { url in
            probed.append(url.path(percentEncoded: false))
            return .ok
        }
        #expect(probed.contains { $0.contains("/Downloads") })
        #expect(places.allSatisfy { $0.access == .readable })
    }

    @Test @MainActor func modelPassesFullDiskAccessToTheCheck() async {
        let model = PlacesModel(check: { granted in
            [Place(id: .oldInstallers, access: granted ? .readable : .locked)]
        })
        await model.refresh(fullDiskAccessGranted: false)
        #expect(model.lockedPlaces.count == 1)
        await model.refresh(fullDiskAccessGranted: true)
        #expect(model.lockedPlaces.isEmpty)
    }

    @Test func lockedSentenceNamesAtMostThree() {
        let locked: [Place] = [.xcodeJunk, .systemCachesAndLogs, .mailDownloads, .trash, .iosBackups]
            .map { Place(id: $0, access: .locked) }
        #expect(PlacesModel.lockedSentence(locked, limit: 3)
            == "Without it, Dustling can't see Xcode data, system caches or Mail downloads.")
        #expect(PlacesModel.lockedSentence(Array(locked.prefix(1)), limit: 3)
            == "Without it, Dustling can't see Xcode data.")
        #expect(PlacesModel.lockedSentence([], limit: 3) == nil)
    }
}
