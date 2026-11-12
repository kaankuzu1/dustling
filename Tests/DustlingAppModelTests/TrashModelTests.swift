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

    /// Settings > Include Trash on external drives governs the Trash tile and Empty Trash too, but only
    /// with Full Disk Access: off, other volumes are left out by choice (not shown as locked).
    @Test func externalTrashSettingGovernsTheTrashWithAccess() async throws {
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
        model.includeExternalVolumes = false
        await model.refresh(fullDiskAccessGranted: true)
        let homeOnly = try #require(model.contents?.size.bytes)
        #expect(homeOnly < 65536)
        #expect(!model.externalVolumesSkipped)

        model.includeExternalVolumes = true
        await model.refresh()
        #expect(try #require(model.contents?.size.bytes) > homeOnly)

        // Without access the setting changes nothing: other volumes stay locked as before.
        await model.refresh(fullDiskAccessGranted: false)
        #expect(model.externalVolumesSkipped)
    }

    @Test func screenshotFixtureNeverEmptiesTheTrash() async throws {
        let rig = try ModelRig()
        let model = makeTrashModel(rig)
        let item = TrashItem(url: URL(filePath: "/sample/Trash/a"), size: SizeResult(bytes: 10, fileCount: 1))
        model.showFixture(items: [item], inTrashBytes: 0)
        #expect(model.contents?.size.bytes == 10)
        guard case .refused = await model.emptyTrash(confirmedBytes: 10) else {
            Issue.record("fixture emptied"); return
        }
        await model.refresh()
        #expect(model.items == [item])   // refresh never re-read the real Trash
    }

    @Test func problemsSummaryNamesEachCause() {
        func entry(_ name: String, _ outcome: DeletionOutcome) -> JournalEntry {
            JournalEntry(originalPath: "/t/\(name)", bytes: 1, outcome: outcome)
        }
        let record = RunRecord(startedAt: Date(), kind: .emptyTrash, entries: [
            entry("a", .deleted), entry("b", .needsAdmin), entry("c", .failed(reason: TrashUnlocker.protectedReason)),
            entry("d", .failed(reason: "boom")), entry("e", .failed(reason: "boom")),
            JournalEntry(originalPath: "<log>", bytes: 0, outcome: .failed(reason: "disk full")),
            JournalEntry(originalPath: "/h/.Trash", bytes: 0, outcome: .failed(reason: "no access, grant Full Disk Access")),
            JournalEntry(originalPath: "/h/.Trash", bytes: 0, outcome: .failed(reason: "trash location is a symbolic link, not emptied")),
        ], restorable: false)
        let problems = EmptyTrashProblems.of(record)
        #expect(problems == EmptyTrashProblems(needsAdmin: 1, protected: 1, failed: 2))
        #expect(problems?.message == "1 item belongs to another account on this Mac, usually because an installer put it there. Open the Trash in Finder and empty it there: Finder asks for your password. 1 item is protected by macOS and can't be deleted. 2 items couldn't be deleted. The log has the reason for each.")
    }

    @Test func problemsSummaryPluralsAndNil() {
        let admin = EmptyTrashProblems(needsAdmin: 5, protected: 0, failed: 0)
        #expect(admin.message.hasPrefix("5 items belong to another account"))
        #expect(admin.message.contains("put them there"))
        #expect(admin.title == "5 items are still in the Trash")
        #expect(EmptyTrashProblems(needsAdmin: 1, protected: 0, failed: 0).title == "1 item is still in the Trash")
        #expect(EmptyTrashProblems(needsAdmin: 0, protected: 3, failed: 0).message == "3 items are protected by macOS and can't be deleted.")
        #expect(EmptyTrashProblems(needsAdmin: 0, protected: 0, failed: 1).message == "1 item couldn't be deleted. The log has the reason for each.")
        let clean = RunRecord(startedAt: Date(), kind: .emptyTrash, entries: [
            JournalEntry(originalPath: "/t/a", bytes: 1, outcome: .deleted)], restorable: false)
        #expect(EmptyTrashProblems.of(clean) == nil)
    }
}

private extension TrashModel {
    /// What the sheet would show and the user confirm.
    var shownBytes: UInt64 { contents?.size.bytes ?? 0 }
}
