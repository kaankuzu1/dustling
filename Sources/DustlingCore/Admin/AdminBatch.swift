import Foundation

/// What the cleanups, the uninstaller, Empty Trash and Put back share when they hand their system
/// items to `AdminMover`: building a move into the Trash, leaving out what the password can't help
/// with yet, and reading a step's result back as a journal outcome.
extension AdminMover {
    /// A move of an item into the user's Trash with the password, planned now.
    struct TrashMove: Sendable {
        let step: AdminStep
        let destination: URL
        /// The item as it was when planned (lstat, owner included). It is the step's
        /// `expectedSource`, and the journal's `trashedIdentity` once the item moved: the script
        /// reports `ok` only when the destination holds this very item, and a rename keeps its
        /// volume, inode, birth time and owner.
        let identity: TrashedIdentity
    }

    /// The item at `url` as it is now (lstat, owner included), or nil when it can't be read. What a
    /// later `trashMove(for:identity:taken:)` expects to move.
    static func identity(of url: URL) -> TrashedIdentity? {
        TrashedIdentity.of(path: AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false)))
    }

    /// `trashMove(for:identity:taken:dependsOn:)` expecting the item that is there now.
    func trashMove(for url: URL, taken: inout Set<String>, dependsOn: Int? = nil) -> TrashMove? {
        guard let identity = Self.identity(of: url) else { return nil }
        return trashMove(for: url, identity: identity, taken: &taken, dependsOn: dependsOn)
    }

    /// The step that moves `url`, expected to be `identity`, to a free name in the Trash
    /// (`trashDestination`, never one in `taken`, which then gets it). Call it right before
    /// `performOpenable`: a name is free only until something else moves to the Trash. A plist
    /// directly in `<system Library>/LaunchDaemons` gets `bootOutDaemon`, so its daemon stops before
    /// it moves. Nil without an owner in `identity`, or when the item can't be renamed into the
    /// Trash (gone, or on another volume).
    func trashMove(
        for url: URL, identity: TrashedIdentity, taken: inout Set<String>, dependsOn: Int? = nil
    ) -> TrashMove? {
        guard let expected = identity.itemIdentity, let destination = trashDestination(for: url, taken: taken)
        else { return nil }
        taken.insert(destination.path(percentEncoded: false))
        let folder = AdminPath.trimmingTrailingSlashes(url.deletingLastPathComponent().path(percentEncoded: false))
        let daemons = AdminPath.trimmingTrailingSlashes(
            environment.systemLibrary.appending(path: "LaunchDaemons").path(percentEncoded: false))
        let step = AdminStep(
            op: .move(from: url, to: destination, bootOutDaemon: folder == daemons),
            dependsOn: dependsOn, expectedSource: expected)
        return TrashMove(step: step, destination: destination, identity: identity)
    }

    /// Whether Dustling's user can open every folder `step` acts in. Planning reads each folder
    /// through a descriptor (`open(O_RDONLY | O_DIRECTORY | O_NOFOLLOW)`), so a folder it can't open
    /// for lack of access (EPERM: no Full Disk Access, which ~/.Trash needs; EACCES: a folder only
    /// root may list) makes `perform` refuse the step as unsafe, although what is missing is access,
    /// not a safe way to do it. Any other failure (a link, a missing folder) is left to planning.
    func canOpenFolders(of step: AdminStep) -> Bool {
        let items: [URL]
        switch step.op {
        case .move(let from, let to, _): items = [from, to]
        case .delete(let url): items = [url]
        }
        return items.allSatisfy { item in
            guard let folder = AdminPath(item)?.folder else { return true }   // refused by the script
            let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            if fd >= 0 {
                close(fd)
                return true
            }
            return code != EPERM && code != EACCES
        }
    }

    /// Whether `identity` is on the volume of the bridge root's script passes every item through
    /// (`/Library`'s). Planning refuses any other item as unsafe, with advice that fits a move into
    /// the Trash, so callers whose item is elsewhere (Empty Trash on an external disk) leave it out.
    func isOnBridgeVolume(_ identity: ItemIdentity) -> Bool {
        ItemIdentity.of(path: planning.bridgeParent, directoryOnly: true)?.device == identity.device
    }

    /// `perform` for one user action, leaving out what the password can't help with yet: a step
    /// whose folders Dustling can't open (`canOpenFolders`) is never sent, nor is a step that
    /// depends on one left out; their result is nil, and the caller keeps the item as it was (still
    /// needing admin). So does a step that came back unsafe because a folder became unopenable
    /// meanwhile. One password box for all the other steps, `prompt(count)` naming how many; none at
    /// all when nothing is left. Results are in the order of `steps`.
    func performOpenable(_ steps: [AdminStep], prompt: (Int) -> String) -> [AdminStepResult?] {
        var sentIndex = [Int?](repeating: nil, count: steps.count)
        var sent: [AdminStep] = []
        for (index, step) in steps.enumerated() {
            var dependsOn = step.dependsOn
            if let earlier = dependsOn, (0..<index).contains(earlier) {
                guard let mapped = sentIndex[earlier] else { continue }
                dependsOn = mapped
            }
            // Any other `dependsOn` stays as it is: still not an earlier step, so the script skips it.
            guard canOpenFolders(of: step) else { continue }
            sentIndex[index] = sent.count
            sent.append(AdminStep(op: step.op, dependsOn: dependsOn, expectedSource: step.expectedSource,
                                  expectedFolder: step.expectedFolder))
        }
        let results = sent.isEmpty ? [] : perform(sent, prompt: prompt(sent.count))
        let refusals: Set<String> = [AdminScript.unsafeReason, AdminScript.putBackUnsafeReason]
        return steps.indices.map { index in
            guard let sentAt = sentIndex[index], results.indices.contains(sentAt) else { return nil }
            let result = results[sentAt]
            if case .notDone(let reason) = result, refusals.contains(reason), !canOpenFolders(of: steps[index]) {
                return nil
            }
            return result
        }
    }

    /// What a move into the Trash with the password leaves in the journal. Done: in the Trash at
    /// `destination`. Not asked (nil) or the password box closed: still needs admin. Already gone:
    /// skipped, as a normal move says. Anything else failed with the script's reason (a `held`
    /// item's reason says where it is kept).
    static func trashOutcome(_ result: AdminStepResult?, destination: URL) -> DeletionOutcome {
        switch result {
        case .done?:
            return .movedToTrash(trashedPath: destination.path(percentEncoded: false))
        case .cancelled?, nil:
            return .needsAdmin
        case .notDone(let reason)?:
            return reason == AdminScript.goneReason ? .skipped(reason: reason) : .failed(reason: reason)
        }
    }
}
