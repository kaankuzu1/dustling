import Foundation

/// Which item a path pointed at: its volume, inode and owner, read with lstat (a link is not
/// followed). Root's script compares these before and after acting, so an item or folder that was
/// swapped behind Dustling's back is never moved or deleted.
public struct ItemIdentity: Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let owner: uid_t

    public init(device: UInt64, inode: UInt64, owner: uid_t) {
        self.device = device
        self.inode = inode
        self.owner = owner
    }

    /// The identity of the item itself (trailing slashes ignored, so a link is never followed);
    /// nil when nothing is there.
    public static func of(_ url: URL) -> ItemIdentity? {
        of(path: AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false)))
    }

    static func of(path: String, directoryOnly: Bool = false) -> ItemIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if directoryOnly, (info.st_mode & S_IFMT) != S_IFDIR { return nil }
        return ItemIdentity(info)
    }

    /// The identity in `info` (from lstat, fstat or fstatat).
    init(_ info: stat) {
        // `stat -f %d` widens the signed dev_t to 64 bits the same way.
        self.init(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), owner: info.st_uid)
    }

    /// As `/usr/bin/stat -f '%d:%i:%u'` prints it.
    var stamp: String { "\(device):\(inode):\(owner)" }
}
