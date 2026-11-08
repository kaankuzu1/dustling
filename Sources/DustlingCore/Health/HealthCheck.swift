import Foundation

public struct HealthReport: Sendable {
    public var fullDiskAccess: FullDiskAccessStatus
    public var storage: StorageInfo?
    /// Plain English sentences describing anything that isn't working.
    public var problems: [String]

    public init(fullDiskAccess: FullDiskAccessStatus, storage: StorageInfo?, problems: [String]) {
        self.fullDiskAccess = fullDiskAccess
        self.storage = storage
        self.problems = problems
    }
}

/// Runs on every launch: re-verifies Full Disk Access and reads storage numbers, and reports
/// anything wrong as a sentence instead of failing silently.
public struct HealthCheck: Sendable {
    private let environment: SystemEnvironment
    private let commands: CommandRunning
    private let volume: URL

    public init(environment: SystemEnvironment, commands: CommandRunning) {
        self.init(environment: environment, commands: commands, volume: URL(filePath: "/"))
    }

    /// Lets tests point the storage reading at a sandbox volume.
    public init(environment: SystemEnvironment, commands: CommandRunning, volume: URL) {
        self.environment = environment
        self.commands = commands
        self.volume = volume
    }

    public func run() -> HealthReport {
        var problems: [String] = []

        let fda = FullDiskAccessProbe(environment: environment).status()
        switch fda {
        case .granted: break
        case .denied:
            problems.append("Full Disk Access is off, so some folders can't be scanned.")
        case .unknown:
            problems.append("Couldn't verify Full Disk Access, so some folders may not be scanned.")
        }

        var storage: StorageInfo?
        do {
            let result = try StorageReader(commands: commands).readWithIssues(volume: volume)
            storage = result.info
            problems += result.problems
        } catch {
            problems.append("Storage numbers unavailable: \(error.localizedDescription)")
        }

        return HealthReport(fullDiskAccess: fda, storage: storage, problems: problems)
    }
}
