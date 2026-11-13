import Foundation

/// Moves and deletes items that belong to the system, asking for the Mac password once per user
/// action: all steps go into one script for one `AdminShell` call. Items keep their owner in the
/// Trash (no chown), so Put back can restore them exactly as they were.
public struct AdminMover: Sendable {
    private let shell: any AdminShell
    let environment: SystemEnvironment
    private let planning: AdminPlanning

    public init(shell: AdminShell, environment: SystemEnvironment) {
        self.init(shell: shell, environment: environment,
                  planning: AdminPlanning(isTrash: AdminPlanning.trash(of: environment)))
    }

    /// `planning` says where the bridge goes and who must own it; tests point it at a sandbox,
    /// since they can't make root-owned folders.
    init(shell: AdminShell, environment: SystemEnvironment, planning: AdminPlanning) {
        self.shell = shell
        self.environment = environment
        self.planning = planning
    }

    /// Where `url` can go in the user's Trash: its own name, or "name 2", "name 3"… when that is
    /// taken. A file or a package (an app) keeps its extension last ("Report 2.pdf", "Tool 2.app");
    /// a folder gets the number at the end ("com.apple.foo 2"). A name is taken when something is
    /// there (lstat, so a dangling link counts) or when its path is in `taken`: the destinations,
    /// as `path(percentEncoded: false)`, already given to earlier steps of the same batch (compared
    /// ignoring case, as the Mac's disk does, and ignoring a trailing slash).
    ///
    /// nil when the item can't be read or is on another volume than the Trash: the script only
    /// renames, so root never copies a whole tree across disks.
    public func trashDestination(for url: URL, taken: Set<String> = []) -> URL? {
        let trash = environment.userTrash
        var item = stat()
        var trashInfo = stat()
        guard lstat(AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false)), &item) == 0,
              stat(trash.path(percentEncoded: false), &trashInfo) == 0,
              item.st_dev == trashInfo.st_dev
        else { return nil }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }

        let isDirectory = (item.st_mode & S_IFMT) == S_IFDIR
        let keepsExtension = !isDirectory || Self.isPackage(url)
        var ext = keepsExtension ? (name as NSString).pathExtension : ""
        var base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        if base.isEmpty { (base, ext) = (name, "") }
        let reserved = Set(taken.map { AdminPath.trimmingTrailingSlashes($0).lowercased() })

        for number in 1...10_000 {
            let candidate = number == 1 ? name : (ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            let destination = trash.appending(path: candidate)
            let path = destination.path(percentEncoded: false)
            var existing = stat()
            let found = lstat(path, &existing) == 0
            let code = errno
            if found || reserved.contains(path.lowercased()) { continue }
            return code == ENOENT ? destination : nil
        }
        return nil
    }

    /// Runs every step in one script. The folders each step acts in and the item itself are read
    /// now (planning, one descriptor per folder); the script refuses a step whose folders or item
    /// changed by the time it runs, checking the item again right before it is renamed. Every item
    /// passes through a private root-only bridge folder in `/Library` (see `AdminScript`).
    /// Refused without running: an item or folder on another volume than `/Library`; a folder that
    /// is not a real directory; `bootOutDaemon` when the plist's folder chain isn't root-only; a move
    /// into a folder the user can't write without the recorded `expectedSource` (Put back's steps
    /// carry it). The reason is `AdminScript.putBackUnsafeReason` ("Dustling can't safely put this
    /// back with your password. Use Put Back in Finder.") for a move out of the environment's Trash,
    /// and `AdminScript.unsafeReason` ("Dustling can't safely move this with your password. Move it
    /// to the Trash in Finder.") for a move into the Trash or a delete.
    /// When something changed while an item was moving and what root took can't safely leave the
    /// bridge, it stays there, untouched. If it is the planned item,
    /// `.notDone(reason: AdminScript.heldReason(bridge:))` names the bridge ("Something changed while
    /// it was moving, so Dustling stopped. It is untouched in /Library/.dustling-XXXXXXXX."); if it
    /// is something else, `AdminScript.movedAwayReason` ("Something changed while it was moving, so
    /// Dustling stopped. Another program may have moved your item.").
    /// No steps: the shell is never called. The password box cancelled: every step is `.cancelled`.
    /// The shell failed: every step is `.notDone` with why.
    public func perform(_ steps: [AdminStep], prompt: String) -> [AdminStepResult] {
        guard !steps.isEmpty else { return [] }
        switch shell.run(script: AdminScript.make(steps, planning: planning), prompt: prompt) {
        case .finished(let output):
            return AdminScript.parse(output, count: steps.count)
        case .cancelled:
            return Array(repeating: .cancelled, count: steps.count)
        case .failed(let reason):
            return Array(repeating: .notDone(reason: reason), count: steps.count)
        }
    }

    public static func movePrompt(count: Int) -> String {
        count == 1
            ? "Dustling needs your password to move 1 item that belongs to the system to the Trash."
            : "Dustling needs your password to move \(count) items that belong to the system to the Trash."
    }

    public static func deletePrompt(count: Int) -> String {
        count == 1
            ? "Dustling needs your password to delete 1 item in the Trash that belongs to the system."
            : "Dustling needs your password to delete \(count) items in the Trash that belong to the system."
    }

    public static func restorePrompt(count: Int) -> String {
        count == 1
            ? "Dustling needs your password to put back 1 item into a system folder."
            : "Dustling needs your password to put back \(count) items into system folders."
    }

    private static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}
