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
            parentAccess: Self.accessErrno(parentPath, W_OK | X_OK),
            parentIsSticky: (parent.st_mode & S_ISVTX) != 0,
            parentOwner: parent.st_uid,
            itemIsDirectory: isDirectory,
            // Only asked for real directories (lstat said so), so access() can't follow a link here.
            itemAccess: isDirectory ? Self.accessErrno(path, W_OK) : 0,
            itemOwner: item.st_uid,
            userID: geteuid())
        switch Self.decide(facts) {
        case .allowed: break
        case .needsAdmin: return .needsAdmin
        case .failed(let reason): return .failed(reason: reason)
        }
        do {
            return .movedToTrash(trashedPath: try backend.trash(url).path(percentEncoded: false))
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// What decides whether an item may be moved out of its folder. The access fields hold the errno of
    /// `access(parent, W_OK|X_OK)` and (for directories) `access(item, W_OK)`, 0 when allowed.
    struct PermissionFacts: Equatable {
        var parentAccess: Int32
        var parentIsSticky: Bool
        var parentOwner: uid_t
        var itemIsDirectory: Bool
        var itemAccess: Int32
        var itemOwner: uid_t
        var userID: uid_t
    }

    enum PermissionDecision: Equatable {
        case allowed, needsAdmin
        case failed(reason: String)
    }

    /// - EPERM from either access check is a privacy (TCC) denial on a folder the user owns: admin
    ///   rights wouldn't help, Full Disk Access would, so it fails with that hint.
    /// - EACCES is a real permission denial: needs admin when the folder can't be changed, or when a
    ///   directory the user can't write would have to move to another folder (its `..` entry changes).
    /// - Any other errno fails with its description.
    /// - A sticky folder (like /tmp) needs admin when the user owns neither the folder nor the item.
    static func decide(_ facts: PermissionFacts) -> PermissionDecision {
        let itemAccess = facts.itemIsDirectory ? facts.itemAccess : 0
        if facts.parentAccess == EPERM || itemAccess == EPERM { return .failed(reason: noAccessReason) }
        for code in [facts.parentAccess, itemAccess] where code != 0 {
            return code == EACCES ? .needsAdmin : .failed(reason: describe(code))
        }
        if facts.parentIsSticky && facts.parentOwner != facts.userID && facts.itemOwner != facts.userID {
            return .needsAdmin
        }
        return .allowed
    }

    /// 0 when `access(path, mode)` succeeds, otherwise its errno (EPERM is a privacy denial on macOS,
    /// EACCES a permission denial).
    private static func accessErrno(_ path: String, _ mode: Int32) -> Int32 {
        access(path, mode) == 0 ? 0 : errno
    }

    /// The C library's English description of an errno (not localized on macOS).
    static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
