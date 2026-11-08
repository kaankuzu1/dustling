import Foundation
@testable import DustlingCore

/// A `CommandRunning` double that records every call and returns canned results.
/// Lookup order: exact (executable + arguments) match, then the default result.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Hashable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var canned: [Call: Result<CommandResult, any Error>] = [:]
    private var fallback: Result<CommandResult, any Error>

    init(default fallback: CommandResult = CommandResult(status: 0, stdout: "", stderr: "")) {
        self.fallback = .success(fallback)
    }

    var calls: [(executable: String, arguments: [String])] {
        lock.lock(); defer { lock.unlock() }
        return _calls.map { ($0.executable, $0.arguments) }
    }

    func setResult(_ result: CommandResult, for executable: String, _ arguments: [String]) {
        lock.lock(); defer { lock.unlock() }
        canned[Call(executable: executable, arguments: arguments)] = .success(result)
    }

    func setError(_ error: any Error, for executable: String, _ arguments: [String]) {
        lock.lock(); defer { lock.unlock() }
        canned[Call(executable: executable, arguments: arguments)] = .failure(error)
    }

    func setDefault(_ result: CommandResult) {
        lock.lock(); defer { lock.unlock() }
        fallback = .success(result)
    }

    func setDefaultError(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        fallback = .failure(error)
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments)
        lock.lock()
        _calls.append(call)
        let outcome = canned[call] ?? fallback
        lock.unlock()
        return try outcome.get()
    }
}
