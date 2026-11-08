import Foundation

/// Throwaway `UserDefaults` suites for tests.
///
/// `UserDefaults(suiteName:)` always writes a plist into `~/Library/Preferences`, and
/// `removePersistentDomain(forName:)` empties it but leaves the file behind, so every test run used
/// to leave hundreds of `dustling-*-<UUID>.plist` files on the developer's Mac. Every suite made
/// here is emptied and its file deleted when the test process exits. Only the suites this process
/// made are touched, so test runs going on at the same time never lose theirs.
enum ScratchDefaults {
    /// A new, empty suite named `<prefix>-<UUID>`.
    static func make(_ prefix: String) -> UserDefaults {
        let name = "\(prefix)-\(UUID().uuidString)"
        registry.add(name)
        return UserDefaults(suiteName: name)!
    }

    private static let registry: Registry = {
        let registry = Registry()
        atexit { ScratchDefaults.registry.removeAll() }
        return registry
    }()

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        func add(_ name: String) {
            lock.withLock { names.append(name) }
        }

        func removeAll() {
            let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
            for name in lock.withLock({ names }) {
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
                try? FileManager.default.removeItem(at: preferences.appending(path: "\(name).plist"))
            }
        }
    }
}
