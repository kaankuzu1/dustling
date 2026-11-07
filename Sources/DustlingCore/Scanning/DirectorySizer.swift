import Foundation

public struct SizeResult: Equatable, Sendable {
    public var bytes: UInt64
    public var fileCount: Int
    public var unreadable: [URL]

    public init(bytes: UInt64 = 0, fileCount: Int = 0, unreadable: [URL] = []) {
        self.bytes = bytes
        self.fileCount = fileCount
        self.unreadable = unreadable
    }
}

/// Measures the space an item really occupies on disk (allocated size). Symlinks are never
/// followed and count as 0. Anything that cannot be read is reported in `unreadable`.
public struct DirectorySizer: Sendable {
    public init() {}

    public func measure(_ url: URL) -> SizeResult {
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

        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else {
                unreadable.append(item)
                continue
            }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            result.bytes += UInt64(values.totalFileAllocatedSize ?? 0)
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
