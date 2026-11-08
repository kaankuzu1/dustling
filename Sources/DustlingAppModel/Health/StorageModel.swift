import DustlingCore
import Foundation
import Observation

/// Disk numbers and purgeable space. A failed read sets `problems` and clears `info`; it never
/// reports zeros as if they were real.
@MainActor @Observable
public final class StorageModel {
    public private(set) var info: StorageInfo?
    public private(set) var problems: [String] = []

    @ObservationIgnored private let read: @Sendable () throws -> (info: StorageInfo, problems: [String])

    public init(read: @escaping @Sendable () throws -> (info: StorageInfo, problems: [String])) {
        self.read = read
    }

    public convenience init(commands: CommandRunning, volume: URL = URL(filePath: "/")) {
        self.init(read: { try StorageReader(commands: commands).readWithIssues(volume: volume) })
    }

    /// Space macOS can reclaim on its own: what "available for important usage" counts beyond what
    /// is truly free. Never negative.
    public var purgeableBytes: Int64 {
        guard let info else { return 0 }
        return max(0, info.availableForImportantUsage - info.availableBytes)
    }

    public func refresh() async {
        let read = self.read
        let result = await Task.detached(priority: .userInitiated) {
            Result { try read() }
        }.value
        switch result {
        case .success(let value):
            info = value.info
            problems = value.problems
        case .failure(let error):
            info = nil
            problems = ["Storage numbers unavailable: \(error.localizedDescription)"]
        }
    }
}
