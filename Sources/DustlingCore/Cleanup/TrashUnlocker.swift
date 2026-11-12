import Darwin
import Foundation

/// Why something in the Trash can't be deleted by this user.
public enum TrashBlocker: Equatable, Sendable {
    /// `count` entries belong to another account and sit in folders this user can't write to
    /// (typically an installer's files: owner root or another uid). Deleting them needs an administrator.
    case otherOwner(count: Int)
    /// An entry the user owns still can't be removed: macOS protects it (system flags).
    case protectedByMacOS
}

/// Makes the user's own locked Trash items deletable (as Finder does) and explains what is left.
/// Never follows symbolic links: walks use `FTS_PHYSICAL`, flags use `lchflags`, and a symlink is
/// never `chmod`ed.
public enum TrashUnlocker {
    /// Clears `uchg`/`uappnd` on everything under `root` (and `root` itself) that `userID` owns, and
    /// gives owned directories owner read, write and search permission. Returns how many entries
    /// it changed. Call only after the user confirmed emptying the Trash.
    @discardableResult
    public static func unlockOwnItems(in root: URL, userID: uid_t) -> Int {
        var total = 0
        // A directory without read permission can't be listed until it is fixed, so walk again
        // while a pass still changes something (a few passes cover any realistic nesting).
        for _ in 0..<8 {
            let changed = unlockPass(root, userID: userID)
            total += changed
            if changed == 0 { break }
        }
        return total
    }

    private static func unlockPass(_ root: URL, userID: uid_t) -> Int {
        var changed = 0
        walk(root) { path, st in
            guard st.st_uid == userID else { return }
            var touched = false
            let userFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
            if st.st_flags & userFlags != 0 {
                if lchflags(path, st.st_flags & ~userFlags) == 0 { touched = true }
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                let want = mode_t(S_IRUSR | S_IWUSR | S_IXUSR)
                if st.st_mode & want != want, chmod(path, (st.st_mode & 0o7777) | want) == 0 { touched = true }
            }
            if touched { changed += 1 }
        }
        return changed
    }

    /// What stops the user deleting what is left under `root`, or nil.
    public static func blocker(of root: URL, userID: uid_t) -> TrashBlocker? {
        blocker(of: root, userID: userID, owner: { url in
            var st = stat()
            return lstat(url.path(percentEncoded: false), &st) == 0 ? st.st_uid : userID
        })
    }

    /// Test seam: `owner` supplies the uid of each entry.
    static func blocker(of root: URL, userID: uid_t, owner: (URL) -> uid_t) -> TrashBlocker? {
        var foreign = 0
        var protected = false
        walk(root) { path, st in
            let url = URL(fileURLWithPath: path)
            let who = owner(url)
            if who != userID {
                let parent = url.deletingLastPathComponent().path(percentEncoded: false)
                if access(parent, W_OK) != 0, errno == EACCES { foreign += 1 }
            } else if st.st_flags & 0xffff_0000 != 0 {   // SF_SETTABLE: system flags only root can clear
                protected = true
            }
        }
        if foreign > 0 { return .otherOwner(count: foreign) }
        return protected ? .protectedByMacOS : nil
    }

    /// Pre-order walk without following symlinks. `body` runs before a directory's children are
    /// read, so it can make the directory readable. Unreadable subtrees are skipped.
    private static func walk(
        _ root: URL, _ body: (_ path: String, _ st: stat) -> Void
    ) {
        let path = root.path(percentEncoded: false)
        guard let dup = strdup(path) else { return }
        defer { free(dup) }
        var argv: [UnsafeMutablePointer<CChar>?] = [dup, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_DNR, FTS_ERR, FTS_NS:
                guard info != FTS_NS, let st = entry.pointee.fts_statp?.pointee else { continue }
                body(String(cString: entry.pointee.fts_path), st)
            default:
                continue
            }
        }
    }
}
