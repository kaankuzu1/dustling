import Foundation

/// The explicit result of removing one item. Nothing is ever dropped silently.
public enum DeletionOutcome: Codable, Equatable, Sendable {
    case movedToTrash(trashedPath: String)
    case skipped(reason: String)
    case failed(reason: String)
    case needsAdmin
    case deleted

    public var label: String {
        switch self {
        case .movedToTrash: "moved to Trash"
        case .skipped(let reason): "skipped: \(reason)"
        case .failed(let reason): "failed: \(reason)"
        case .needsAdmin: "needs admin"
        case .deleted: "deleted"
        }
    }
}
