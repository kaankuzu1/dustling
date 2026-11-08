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
