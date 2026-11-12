import Foundation

/// Moves and deletes items that belong to the system, asking for the Mac password once per user
/// action: all steps go into one script for one `AdminShell` call. Items keep their owner in the
/// Trash (no chown), so Put back can restore them exactly as they were.
public struct AdminMover: Sendable {
    private let shell: any AdminShell
    private let environment: SystemEnvironment

    public init(shell: AdminShell, environment: SystemEnvironment) {
        self.shell = shell
        self.environment = environment
    }

    /// Where `url` can go in the user's Trash: its own name, or "name 2", "name 3"… when that is
    /// taken. A file or a package (an app) keeps its extension last ("Report 2.pdf", "Tool 2.app");
    /// a folder gets the number at the end ("com.apple.foo 2"). A name is taken when something is
    /// there (lstat, so a dangling link counts) or when its path is in `taken`: the destinations,
    /// as `path(percentEncoded: false)`, already given to earlier steps of the same batch (compared
    /// ignoring case, as the Mac's disk does).
    ///
    /// nil when the item can't be read or is on another volume than the Trash: the script only
    /// renames, so root never copies a whole tree across disks.
    public func trashDestination(for url: URL, taken: Set<String> = []) -> URL? {
        let trash = environment.userTrash
        var item = stat()
        var trashInfo = stat()
        guard lstat(url.path(percentEncoded: false), &item) == 0,
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
        let reserved = Set(taken.map { $0.lowercased() })

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

    /// Runs every step in one script. No steps: the shell is never called. The password box
    /// cancelled: every step is `.cancelled`. The shell failed: every step is `.notDone` with why.
    public func perform(_ steps: [AdminStep], prompt: String) -> [AdminStepResult] {
        guard !steps.isEmpty else { return [] }
        switch shell.run(script: AdminScript.make(steps), prompt: prompt) {
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
