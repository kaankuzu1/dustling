import Foundation

public struct SizeResult: Equatable, Sendable {
    public var bytes: UInt64
    public var fileCount: Int
    public var unreadable: [URL]
    /// True when measuring was stopped early: `bytes` and `fileCount` are then only what was seen so far.
    public var cancelled: Bool

    public init(bytes: UInt64 = 0, fileCount: Int = 0, unreadable: [URL] = [], cancelled: Bool = false) {
        self.bytes = bytes
        self.fileCount = fileCount
        self.unreadable = unreadable
        self.cancelled = cancelled
    }
}

/// Measures the space an item really occupies on disk (allocated size). Symlinks are never
/// followed and count as 0. Anything that cannot be read is reported in `unreadable`.
public struct DirectorySizer: Sendable {
    public init() {}

    /// `isCancelled` is polled for every entry; when it returns true, measuring stops and the result
    /// is marked `cancelled` (its numbers are partial).
    public func measure(_ url: URL, isCancelled: () -> Bool = { false }) -> SizeResult {
        measure(url, isCancelled: isCancelled, onEntry: nil)
    }

    /// Like `measure(_:isCancelled:)`, and calls `onEntry(path, bytesSoFar)` on the first entry and then
    /// every 128 entries, so a caller can show live progress inside one huge folder.
    func measure(
        _ url: URL, isCancelled: () -> Bool, onEntry: ((URL, UInt64) -> Void)?
    ) -> SizeResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey, .isRegularFileKey]
        var result = SizeResult()

        guard (try? fm.attributesOfItem(atPath: url.path)) != nil || isSymlink(url) else {
            result.unreadable.append(url)
            return result
        }
        if isSymlink(url) { return result }

        var isDirectory: ObjCBool = false
        _ = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if !isDirectory.boolValue {
            if let size = allocatedSize(of: url) {
                result.bytes = size
                result.fileCount = 1
            } else {
                result.unreadable.append(url)
            }
            return result
        }

        var unreadable: [URL] = []
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [],
            errorHandler: { failedURL, _ in
                unreadable.append(failedURL)
                return true
            })
        else {
            result.unreadable.append(url)
            return result
        }

        var seen = 0
        for case let item as URL in enumerator {
            if isCancelled() {
                result.cancelled = true
                break
            }
            seen += 1
            if seen & 127 == 1 { onEntry?(item, result.bytes) }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else {
                unreadable.append(item)
                continue
            }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            guard let size = values.totalFileAllocatedSize else {
                unreadable.append(item)
                continue
            }
            result.bytes += UInt64(size)
            result.fileCount += 1
        }
        result.unreadable = unreadable
        return result
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func allocatedSize(of url: URL) -> UInt64? {
        guard let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let size = v.totalFileAllocatedSize else { return nil }
        return UInt64(size)
    }
}
