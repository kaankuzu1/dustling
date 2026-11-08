import Foundation

public struct TrashMover: Sendable {
    private let backend: TrashBackend
    private let protectedPaths: ProtectedPaths

    static let noAccessReason = "no access (Full Disk Access may be needed)"

    public init(backend: TrashBackend, protectedPaths: ProtectedPaths) {
        self.backend = backend
        self.protectedPaths = protectedPaths
    }

    public func moveToTrash(_ url: URL, allowedRoots: [URL]) -> DeletionOutcome {
        if case .denied(let reason) = protectedPaths.verdict(for: url, allowedRoots: allowedRoots) {
            return .skipped(reason: reason)
        }
        let path = url.path(percentEncoded: false)
        // lstat semantics: a dangling symlink still exists and can be trashed as a link.
        var item = stat()
        if lstat(path, &item) != 0 {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR: return .skipped(reason: "already gone")
            case EPERM, EACCES: return .failed(reason: Self.noAccessReason)
            default: return .failed(reason: Self.describe(code))
            }
        }
        let parentPath = url.deletingLastPathComponent().path(percentEncoded: false)
        var parent = stat()
        if stat(parentPath, &parent) != 0 {
            let code = errno
            return .failed(reason: code == EPERM || code == EACCES ? Self.noAccessReason : Self.describe(code))
        }
        let isDirectory = (item.st_mode & S_IFMT) == S_IFDIR
        let facts = PermissionFacts(
            parentWritableAndSearchable: access(parentPath, W_OK | X_OK) == 0,
            parentIsSticky: (parent.st_mode & S_ISVTX) != 0,
            parentOwner: parent.st_uid,
            itemIsDirectory: isDirectory,
            // Only asked for real directories (lstat said so), so access() can't follow a link here.
            itemWritable: !isDirectory || access(path, W_OK) == 0,
            itemOwner: item.st_uid,
            userID: geteuid())
        if Self.needsAdmin(facts) {
            return .needsAdmin
        }
        do {
            return .movedToTrash(trashedPath: try backend.trash(url).path(percentEncoded: false))
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// What decides whether moving an item out of its folder needs admin rights.
    struct PermissionFacts: Equatable {
        var parentWritableAndSearchable: Bool
        var parentIsSticky: Bool
        var parentOwner: uid_t
        var itemIsDirectory: Bool
        var itemWritable: Bool
        var itemOwner: uid_t
        var userID: uid_t
    }

    /// Needs admin when the folder can't be changed by the user, when a directory the user can't
    /// write would have to move to another folder (its `..` entry changes), or when the folder is
    /// sticky (like /tmp) and the user owns neither the folder nor the item.
    static func needsAdmin(_ facts: PermissionFacts) -> Bool {
        if !facts.parentWritableAndSearchable { return true }
        if facts.itemIsDirectory && !facts.itemWritable { return true }
        if facts.parentIsSticky && facts.parentOwner != facts.userID && facts.itemOwner != facts.userID {
            return true
        }
        return false
    }

    /// The C library's English description of an errno (not localized on macOS).
    static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
