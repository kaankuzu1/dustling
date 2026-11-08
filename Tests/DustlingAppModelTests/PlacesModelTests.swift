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
        let containers = rig.environment.userLibrary.appending(path: "Containers").path(percentEncoded: false)
        #expect(!probed.contains { $0.hasPrefix(downloads) })
        // Other apps' containers ask "access data from other apps" without Full Disk Access.
        #expect(!probed.contains { $0.hasPrefix(containers) })
        #expect(places.filter { $0.access == .locked }.map(\.id)
            == [.userCaches, .oldInstallers, .largeOldDownloads, .mailDownloads])
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
        #expect(probed.contains { $0.hasSuffix("/Library/Containers") })
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

    @Test func otherErrorsMakeAPlaceUnreadableNotReadable() throws {
        let rig = try ModelRig()
        let categories = JunkCatalog.standard(rig.environment, options: rig.options)
        let logs = rig.environment.userLibrary.appending(path: "Logs").path(percentEncoded: false)
        for granted in [false, true] {
            let places = PlaceAccessChecker.check(categories, fullDiskAccessGranted: granted) { url in
                url.path(percentEncoded: false) == logs ? .other(EIO) : .ok
            }
            #expect(places.first { $0.id == .userLogs }?.access == .unreadable)
            #expect(places.filter { $0.access != .readable }.count == 1)
        }
    }

    @Test func refusalWithFullDiskAccessOnIsNotBlamedOnIt() throws {
        let rig = try ModelRig()
        let categories = JunkCatalog.standard(rig.environment, options: rig.options)
        let trash = rig.environment.userTrash.standardizedFileURL.path(percentEncoded: false)
        let probe: (URL) -> PlaceAccessChecker.PathAccess = { url in
            url.standardizedFileURL.path(percentEncoded: false) == trash ? .denied : .ok
        }
        let off = PlaceAccessChecker.check(categories, fullDiskAccessGranted: false, probe: probe)
        #expect(off.first { $0.id == .trash }?.access == .locked)
        let on = PlaceAccessChecker.check(categories, fullDiskAccessGranted: true, probe: probe)
        #expect(on.first { $0.id == .trash }?.access == .unreadable)
        #expect(!on.contains { $0.access == .locked })
    }

    @Test func lockedWinsOverUnreadableInOnePlace() throws {
        let rig = try ModelRig()
        let categories = JunkCatalog.standard(rig.environment, options: rig.options)
        let system = categories.first { $0.id == .systemCachesAndLogs }!
        let first = system.roots[0].path(percentEncoded: false)
        let places = PlaceAccessChecker.check([system], fullDiskAccessGranted: false) { url in
            url.path(percentEncoded: false) == first ? .other(ELOOP) : .denied
        }
        #expect(places.first?.access == .locked)
    }

    @Test @MainActor func unreadablePlacesAreNotCountedAsNeedingFullDiskAccess() async {
        let model = PlacesModel(check: { _ in
            [Place(id: .userLogs, access: .unreadable), Place(id: .trash, access: .locked),
             Place(id: .browserCaches, access: .readable)]
        })
        await model.refresh(fullDiskAccessGranted: false)
        #expect(model.lockedPlaces.map(\.id) == [.trash])
        #expect(model.unreadablePlaces.map(\.id) == [.userLogs])
        #expect(model.readableCount == 1)
        #expect(model.unreadableSentence == "Dustling can't read the folder for app logs.")
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
