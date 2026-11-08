import Foundation

public struct StorageInfo: Equatable, Sendable {
    public var totalBytes: Int64
    /// What macOS's updater counts as free: includes purgeable space.
    public var availableForImportantUsage: Int64
    /// Truly free space. `availableForImportantUsage - availableBytes` is the purgeable amount.
    public var availableBytes: Int64
    public var localSnapshotCount: Int

    public init(
        totalBytes: Int64, availableForImportantUsage: Int64,
        availableBytes: Int64, localSnapshotCount: Int
    ) {
        self.totalBytes = totalBytes
        self.availableForImportantUsage = availableForImportantUsage
        self.availableBytes = availableBytes
        self.localSnapshotCount = localSnapshotCount
    }
}

public struct StorageReader: Sendable {
    private let commands: CommandRunning

    public init(commands: CommandRunning) {
        self.commands = commands
    }

    /// Reads storage numbers. A failing `tmutil` yields a snapshot count of 0; use
    /// `readWithIssues` to learn about that.
    public func read(volume: URL = URL(filePath: "/")) throws -> StorageInfo {
        try readWithIssues(volume: volume).info
    }

    /// Like `read`, plus plain-sentence problems for anything that degraded (for example
    /// `tmutil` failing, so the 0 snapshot count is not a verified fact). Throws only if the
    /// volume's capacity values can't be read.
    public func readWithIssues(volume: URL = URL(filePath: "/")) throws -> (info: StorageInfo, problems: [String]) {
        let values = try volume.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity,
              let important = values.volumeAvailableCapacityForImportantUsage
        else {
            throw CocoaError(.fileReadUnknown)
        }

        var problems: [String] = []
        var snapshots = 0
        do {
            let result = try commands.run("/usr/bin/tmutil", ["listlocalsnapshots", volume.path])
            if result.status == 0 {
                snapshots = result.stdout.split(whereSeparator: \.isNewline)
                    .filter { $0.contains("com.apple.TimeMachine.") }.count
            } else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                problems.append("Couldn't check Time Machine local snapshots: "
                    + (detail.isEmpty ? "tmutil exited with status \(result.status)" : detail))
            }
        } catch {
            problems.append("Couldn't check Time Machine local snapshots: \(error.localizedDescription)")
        }

        let info = StorageInfo(
            totalBytes: Int64(total), availableForImportantUsage: important,
            availableBytes: Int64(available), localSnapshotCount: snapshots)
        return (info, problems)
    }
}
