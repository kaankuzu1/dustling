import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs an external program to completion. Injectable so tests never spawn real processes.
public protocol CommandRunning: Sendable {
    /// Throws if the executable cannot be launched. A non-zero exit status is NOT an error;
    /// it is reported in the result.
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain both pipes concurrently so a full pipe buffer can never block the child. Dedicated
        // threads, not the global queue: when callers block every Swift concurrency thread in here
        // (parallel tests do), GCD starts no thread for the global queue and the wait never ends.
        let box = OutputBox()
        let group = DispatchGroup()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            Thread.detachNewThread {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.store(data, isOut: isOut)
                group.leave()
            }
        }
        process.waitUntilExit()
        group.wait()
        let (out, err) = box.snapshot()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self))
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func store(_ data: Data, isOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isOut { out = data } else { err = data }
    }

    func snapshot() -> (Data, Data) {
        lock.lock(); defer { lock.unlock() }
        return (out, err)
    }
}
