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
        let result = await model.emptyTrash()
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

        guard case .emptied(let record) = await model.emptyTrash() else { Issue.record("expected emptied"); return }

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
        guard case .refused(let reason) = await model.emptyTrash() else { Issue.record("expected refused"); return }
        #expect(!reason.isEmpty)
    }

    @Test func secondEmptyWhileRunningIsRefused() async throws {
        let rig = try ModelRig()
        try rig.file(rig.environment.userTrash.appending(path: "old.txt"), bytes: 4096)
        let completed = Counter()
        let model = makeTrashModel(rig, onRunCompleted: { completed.bump() })
        await model.refresh()
        async let first = model.emptyTrash()
        async let second = model.emptyTrash()
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

        guard case .refused = await model.emptyTrash() else { Issue.record("expected refused"); return }

        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        // The model re-read the Trash, so the UI can confirm the new size.
        #expect((model.contents?.size.bytes ?? 0) > 4096)
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
        await junk.clean()
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
        await junk.clean()
        guard case .done(let second) = junk.state else { Issue.record("expected done"); return }
        await model.refresh()
        #expect(model.inTrashBytesSinceLastEmpty == second.bytesMovedToTrash)
        #expect(model.inTrashBytesSinceLastEmpty > 0)

        guard case .emptied = await model.emptyTrash() else { Issue.record("expected emptied"); return }
        #expect(model.inTrashBytesSinceLastEmpty == 0)
    }
}
