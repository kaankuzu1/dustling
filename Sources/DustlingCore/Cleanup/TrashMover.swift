import Foundation

public struct TrashMover: Sendable {
    private let backend: TrashBackend
    private let protectedPaths: ProtectedPaths

    public init(backend: TrashBackend, protectedPaths: ProtectedPaths) {
        self.backend = backend
        self.protectedPaths = protectedPaths
    }

    public func moveToTrash(_ url: URL, allowedRoots: [URL]) -> DeletionOutcome {
        if case .denied(let reason) = protectedPaths.verdict(for: url, allowedRoots: allowedRoots) {
            return .skipped(reason: reason)
        }
        // lstat semantics: a dangling symlink still exists and can be trashed as a link.
        if (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) == nil {
            return .skipped(reason: "already gone")
        }
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        if access(parent, W_OK) != 0 {
            return .needsAdmin
        }
        do {
            return .movedToTrash(trashedPath: try backend.trash(url).path(percentEncoded: false))
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}
