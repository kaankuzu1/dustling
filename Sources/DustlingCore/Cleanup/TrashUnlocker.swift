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
/// Never follows symbolic links or crosses into another file system: walks use
/// `FTS_PHYSICAL | FTS_XDEV`, flags use `lchflags`, modes use `fchmodat(AT_SYMLINK_NOFOLLOW)`.
public enum TrashUnlocker {
    /// The reason recorded (and shown) for an item macOS protects. Shared by every deleter.
    public static let protectedReason = "protected by macOS"

    /// Clears `uchg`/`uappnd` on everything under `root` (and `root` itself) that `userID` owns, and
    /// gives owned directories owner read, write and search permission. Returns how many entries
    /// it changed. Files with several hard links keep their flags (clearing them would unlock
    /// the same file outside the Trash too). Call only after the user confirmed emptying the Trash.
    @discardableResult
    public static func unlockOwnItems(in root: URL, userID: uid_t) -> Int {
        var changed = 0
        // One pass is enough: the body runs when fts reaches a directory, before it reads the
        // directory's children, so a folder without read permission is fixed before it is listed.
        walk(root) { path, st, info, _ in
            guard info != FTS_DNR, info != FTS_ERR, info != FTS_NS, st.st_uid == userID else { return }
            let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
            var touched = false
            let userFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
            if st.st_flags & userFlags != 0, isDirectory || st.st_nlink <= 1 {
                if lchflags(path, st.st_flags & ~userFlags) == 0 { touched = true }
            }
            if isDirectory {
                let want = mode_t(S_IRUSR | S_IWUSR | S_IXUSR)
                if st.st_mode & want != want,
                   fchmodat(AT_FDCWD, path, (st.st_mode & 0o7777) | want, AT_SYMLINK_NOFOLLOW) == 0 {
                    touched = true
                }
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

    /// Test seam: `owner` supplies the uid of each entry; `failure` makes an entry read as unreadable
    /// with that errno (a really protected folder can't be made without root).
    static func blocker(
        of root: URL, userID: uid_t, owner: (URL) -> uid_t, failure: (URL) -> Int32? = { _ in nil }
    ) -> TrashBlocker? {
        var foreign = 0
        var protected = false
        walk(root) { path, st, walkInfo, walkErr in
            let url = URL(fileURLWithPath: path)
            let forced = failure(url)
            let info = forced == nil ? walkInfo : FTS_DNR
            let err = forced ?? walkErr
            let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
            if owner(url) != userID {
                let parent = url.deletingLastPathComponent().path(percentEncoded: false)
                if access(parent, W_OK) != 0, errno == EACCES {
                    foreign += 1   // can't be unlinked from its folder
                } else if isDirectory, info == FTS_D, access(path, W_OK) != 0, errno == EACCES,
                          ((try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == false) {
                    foreign += 1   // its children can't be unlinked
                }
                return
            }
            let unreadable = info == FTS_DNR || info == FTS_NS || info == FTS_ERR
            if unreadable && err == EPERM {
                protected = true
            } else if info != FTS_NS {
                if st.st_flags & 0xffff_0000 != 0 {   // SF_SETTABLE: system flags only root can clear
                    protected = true
                } else if !isDirectory, st.st_nlink > 1, st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
                    protected = true   // locked hard link: unlock leaves it alone
                }
            }
        }
        if foreign > 0 { return .otherOwner(count: foreign) }
        return protected ? .protectedByMacOS : nil
    }

    /// Pre-order walk without following symlinks or leaving the file system. `body` gets the path,
    /// its `stat` (zeroed when unavailable), `fts_info` and `fts_errno`, and runs before a
    /// directory's children are read.
    private static func walk(
        _ root: URL, _ body: (_ path: String, _ st: stat, _ info: Int32, _ err: Int32) -> Void
    ) {
        let path = root.path(percentEncoded: false)
        guard let dup = strdup(path) else { return }
        defer { free(dup) }
        var argv: [UnsafeMutablePointer<CChar>?] = [dup, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_DNR, FTS_ERR, FTS_NS:
                let st = entry.pointee.fts_statp?.pointee ?? stat()
                body(String(cString: entry.pointee.fts_path), st, info, entry.pointee.fts_errno)
            default:
                continue
            }
        }
    }
}
