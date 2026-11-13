import Foundation

/// The locations Dustling reads from and writes to. Injectable so tests never touch the real system.
public struct SystemEnvironment: Sendable {
    public var home: URL
    public var applicationDirectories: [URL]
    public var systemLibrary: URL
    public var volumesDirectory: URL
    public var userID: uid_t

    public init(
        home: URL,
        applicationDirectories: [URL],
        systemLibrary: URL,
        volumesDirectory: URL,
        userID: uid_t
    ) {
        self.home = home
        self.applicationDirectories = applicationDirectories
        self.systemLibrary = systemLibrary
        self.volumesDirectory = volumesDirectory
        self.userID = userID
    }

    public var userLibrary: URL { home.appending(path: "Library") }
    public var userTrash: URL { home.appending(path: ".Trash") }
    public var logsDirectory: URL { home.appending(path: "Library/Logs/Dustling") }
    public var historyDirectory: URL { home.appending(path: "Library/Application Support/Dustling/History") }

    /// The system's caches and logs (`<systemLibrary>/Caches`, `<systemLibrary>/Logs`): the folders of
    /// System caches and logs. macOS manages them, so nothing in them is ever cleaned
    /// (`JunkCategory.isNeverCleaned`); `ProtectedPaths` refuses every move from them.
    public var systemManagedFolders: [URL] {
        ["Caches", "Logs"].map { systemLibrary.appending(path: $0) }
    }

    /// True when `path` is inside one of `systemManagedFolders`, judged by its text alone (case
    /// ignored, as APFS does) without reading the disk. For how an older run's items read and what a
    /// retry leaves out; what may move is decided by `ProtectedPaths`.
    public func isSystemManaged(_ path: String) -> Bool {
        func parts(_ text: String) -> [String] {
            text.split(separator: "/", omittingEmptySubsequences: true).map { $0.lowercased() }
        }
        let item = parts(path)
        return systemManagedFolders.contains { folder in
            let base = parts(folder.path(percentEncoded: false))
            return item.count > base.count && Array(item.prefix(base.count)) == base
        }
    }

    public static var current: SystemEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SystemEnvironment(
            home: home,
            applicationDirectories: [URL(filePath: "/Applications"), home.appending(path: "Applications")],
            systemLibrary: URL(filePath: "/Library"),
            volumesDirectory: URL(filePath: "/Volumes"),
            userID: getuid()
        )
    }
}
