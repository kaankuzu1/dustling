import Foundation

public protocol TrashBackend: Sendable {
    /// Moves `url` to the Trash and returns where it ended up.
    func trash(_ url: URL) throws -> URL
}

public struct TrashBackendError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Moves items to the user's real Trash. Never use this in tests.
public struct SystemTrashBackend: TrashBackend {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let result = resulting as URL? else {
            throw TrashBackendError(message: "the Trash did not report where the item went")
        }
        return result
    }
}
