import Foundation
@testable import DustlingCore

/// A throwaway directory tree that mirrors the real macOS layout. Relative paths passed to the
/// helpers are relative to `root`:
///
///     <root>/home                 -> environment.home
///     <root>/home/Applications    -> environment.applicationDirectories[1]
///     <root>/Applications         -> environment.applicationDirectories[0]
///     <root>/Library              -> environment.systemLibrary
///     <root>/Volumes              -> environment.volumesDirectory
///
/// The tree is removed when the sandbox is deallocated.
final class TestSandbox {
    let root: URL
    let environment: SystemEnvironment

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "dustling-test-\(UUID().uuidString)")
        root = base
        let home = base.appending(path: "home")
        let apps = base.appending(path: "Applications")
        let userApps = home.appending(path: "Applications")
        let library = base.appending(path: "Library")
        let volumes = base.appending(path: "Volumes")
        for dir in [home, apps, userApps, library, volumes] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        environment = SystemEnvironment(
            home: home,
            applicationDirectories: [apps, userApps],
            systemLibrary: library,
            volumesDirectory: volumes,
            userID: getuid()
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ relativePath: String, bytes: Int = 1) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a minimal `.app` bundle at `relativePath` (include the `.app` suffix).
    @discardableResult
    func app(
        _ relativePath: String,
        bundleID: String?,
        executable: String = "App",
        script: String? = nil
    ) throws -> URL {
        let url = try directory(relativePath)
        let macOS = try directory(relativePath + "/Contents/MacOS")
        var plist: [String: Any] = ["CFBundleExecutable": executable]
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appending(path: "Contents/Info.plist"))
        let exe = macOS.appending(path: executable)
        try Data((script ?? "stub").utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return url
    }
}
