import Foundation
import Testing
import DustlingCore
@testable import DustlingAppModel

@MainActor
struct TrashModelTests {
    private func makeTrashModel(_ rig: ModelRig, onRunCompleted: @escaping @MainActor () -> Void = {}) -> TrashModel {
        TrashModel(inspector: rig.trashInspector(), journal: rig.journal, onRunCompleted: onRunCompleted)
    }

    @Test func emptyTrashDisabledWhenTrashUnreadable() async throws {
        let rig = try ModelRig()
        let old = try rig.file(rig.environment.userTrash.appending(path: "old.txt"), bytes: 4096)
        // Take away read access: the Trash can't be listed, as without Full Disk Access.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: rig.environment.userTrash.path(percentEncoded: false))
        let model = makeTrashModel(rig)
        #expect(!model.canEmpty)   // before the first look, never enabled

        await model.refresh()

        #expect(!model.canEmpty)
        #expect(model.contents?.issues.isEmpty == false)
        #expect(model.disabledReason == "Dustling can't see inside the Trash without Full Disk Access")
        let result = await model.emptyTrash(confirmedBytes: model.shownBytes)
        guard case .refused = result else { Issue.record("expected refused"); return }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: rig.environment.userTrash.path(percentEncoded: false))
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func emptyTrashDisabledWhenTrashIsEmpty() async throws {
        let rig = try ModelRig()
        try FileManager.default.createDirectory(at: rig.environment.userTrash, withIntermediateDirectories: true)
        let model = makeTrashModel(rig)
        await model.refresh()
        #expect(!model.canEmpty)
        #expect(model.disabledReason == "The Trash is empty")
    }

    @Test func emptyTrashEnabledWhenReadableAndNotEmpty() async throws {
        let rig = try ModelRig()
        try rig.file(rig.environment.userTrash.appending(path: "old.txt"), bytes: 4096)
        let model = makeTrashModel(rig)
        await model.refresh()
        #expect(model.canEmpty)
        #expect(model.disabledReason == nil)
        #expect((model.contents?.size.bytes ?? 0) > 0)
    }

    @Test func emptyTrashDeletesAndRefreshes() async throws {
        let rig = try ModelRig()
        let old = try rig.file(rig.environment.userTrash.appending(path: "old.txt"), bytes: 4096)
        let completed = Counter()
        let model = makeTrashModel(rig, onRunCompleted: { completed.bump() })
        await model.refresh()

        guard case .emptied(let record) = await model.emptyTrash(confirmedBytes: model.shownBytes) else { Issue.record("expected emptied"); return }

        #expect(record.kind == .emptyTrash)
        #expect(record.entries.contains { $0.outcome == .deleted })
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!model.canEmpty)
        #expect(model.disabledReason == "The Trash is empty")
        #expect(completed.value == 1)
    }

    @Test func emptyTrashRefusesWhenItCannotBeEmptied() async throws {
        let rig = try ModelRig()
        let model = makeTrashModel(rig)   // never looked at the Trash
        guard case .refused(let reason) = await model.emptyTrash(confirmedBytes: model.shownBytes) else { Issue.record("expected refused"); return }
        #expect(!reason.isEmpty)
    }

    @Test func secondEmptyWhileRunningIsRefused() async throws {
        let rig = try ModelRig()
        try rig.file(rig.environment.userTrash.appending(path: "old.txt"), bytes: 4096)
        let completed = Counter()
        let model = makeTrashModel(rig, onRunCompleted: { completed.bump() })
        await model.refresh()
        async let first = model.emptyTrash(confirmedBytes: model.shownBytes)
        async let second = model.emptyTrash(confirmedBytes: model.shownBytes)
        let results = await [first, second]
        let emptied = results.filter { if case .emptied = $0 { true } else { false } }
        #expect(emptied.count == 1)
        #expect(completed.value == 1)
    }

    @Test func trashChangedSinceConfirmationIsRefusedAndNothingDeleted() async throws {
        let rig = try ModelRig()
        let old = try rig.file(rig.environment.userTrash.appending(path: "old.txt"), bytes: 4096)
        let model = makeTrashModel(rig)
        await model.refresh()
        let fresh = try rig.file(rig.environment.userTrash.appending(path: "new.txt"), bytes: 8192)

        guard case .refused = await model.emptyTrash(confirmedBytes: model.shownBytes) else { Issue.record("expected refused"); return }

        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        // The model re-read the Trash, so the UI can confirm the new size.
        #expect((model.contents?.size.bytes ?? 0) > 4096)
    }

    @Test func emptyTrashDeletesOnlyTheSizeTheSheetShowed() async throws {
        let rig = try ModelRig()
        let old = try rig.file(rig.environment.userTrash.appending(path: "old.txt"), bytes: 4096)
        let model = makeTrashModel(rig)
        await model.refresh()
        let shown = try #require(model.contents?.size.bytes)

        guard case .refused = await model.emptyTrash(confirmedBytes: shown + 1) else {
            Issue.record("expected refused"); return
        }
        #expect(FileManager.default.fileExists(atPath: old.path))

        guard case .emptied = await model.emptyTrash(confirmedBytes: shown) else { Issue.record("expected emptied"); return }
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func trashItemsAreListedForTheSheet() async throws {
        let rig = try ModelRig()
        try rig.file(rig.environment.userTrash.appending(path: "small.txt"), bytes: 100)
        try rig.file(rig.environment.userTrash.appending(path: "big.bin"), bytes: 8192)
        let model = makeTrashModel(rig)
        #expect(model.items.isEmpty)
        await model.refresh()
        #expect(Set(model.items.map(\.url.lastPathComponent)) == ["small.txt", "big.bin"])
    }

    @Test func inTrashBytesFeedMosaicUntilEmptied() async throws {
        let rig = try ModelRig()
        try rig.file(rig.cachesDirectory.appending(path: "a.log"), bytes: 4096)
        try rig.file(rig.cachesDirectory.appending(path: "b.log"), bytes: 8192)
        let categories = rig.categories()
        let junk = JunkScanModel(
            scanner: rig.scanner(), runner: rig.runner(), journal: rig.journal,
            environment: rig.environment, options: rig.options, categories: { categories })
        junk.scan()
        await junk.awaitScan()
        await junk.clean(confirmedLimited: true)
        guard case .done(let record) = junk.state else { Issue.record("expected done"); return }
        #expect(record.bytesMovedToTrash > 0)

        let model = makeTrashModel(rig)
        #expect(model.inTrashBytesSinceLastEmpty == 0)
        await model.refresh()
        #expect(model.inTrashBytesSinceLastEmpty == record.bytesMovedToTrash)

        // Putting items back takes them out of the Trash, so they no longer count.
        _ = try await junk.putEverythingBack()
        await model.refresh()
        #expect(model.inTrashBytesSinceLastEmpty == 0)

        // Clean again: counted again, until the Trash is emptied.
        junk.scan()
        await junk.awaitScan()
        await junk.clean(confirmedLimited: true)
        guard case .done(let second) = junk.state else { Issue.record("expected done"); return }
        await model.refresh()
        #expect(model.inTrashBytesSinceLastEmpty == second.bytesMovedToTrash)
        #expect(model.inTrashBytesSinceLastEmpty > 0)

        guard case .emptied = await model.emptyTrash(confirmedBytes: model.shownBytes) else { Issue.record("expected emptied"); return }
        #expect(model.inTrashBytesSinceLastEmpty == 0)
    }

    @Test func withoutFullDiskAccessOnlyTheHomeTrashIsRead() async throws {
        let rig = try ModelRig()
        try rig.file(rig.environment.userTrash.appending(path: "home.bin"), bytes: 4096)
        let stick = rig.environment.volumesDirectory.appending(path: "Stick/.Trashes/\(rig.environment.userID)")
        try rig.file(stick.appending(path: "far.bin"), bytes: 65536)
        let environment = rig.environment, journal = rig.journal
        let model = TrashModel(
            makeInspector: { external in
                TrashInspector(
                    environment: environment, journal: journal,
                    logger: RunLogger(directory: environment.logsDirectory), sizer: DirectorySizer(),
                    includeExternalVolumes: external)
            },
            journal: rig.journal)

        await model.refresh(fullDiskAccessGranted: false)
        let homeOnly = try #require(model.contents?.size.bytes)
        #expect(model.externalVolumesSkipped)
        #expect(homeOnly < 65536)

        await model.refresh(fullDiskAccessGranted: true)
        #expect(!model.externalVolumesSkipped)
        #expect(try #require(model.contents?.size.bytes) > homeOnly)
    }
}

private extension TrashModel {
    /// What the sheet would show and the user confirm.
    var shownBytes: UInt64 { contents?.size.bytes ?? 0 }
}
