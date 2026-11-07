import Foundation

/// Finds the files an app left (or would leave) behind. Bundle IDs, team IDs, display names and
/// Steam `installdir` values come from untrusted files, so each is validated before it becomes a
/// path component, and every result is a direct child of a fixed, declared location directory.
public struct LeftoverFinder: Sendable {
    private let environment: SystemEnvironment
    private let sizer: DirectorySizer
    private let commands: any CommandRunning

    private static let pkgutil = "/usr/sbin/pkgutil"
    private static let receiptsDirectory = URL(filePath: "/private/var/db/receipts", directoryHint: .isDirectory)

    public init(environment: SystemEnvironment, sizer: DirectorySizer, commands: any CommandRunning) {
        self.environment = environment
        self.sizer = sizer
        self.commands = commands
    }

    public func leftovers(for app: InstalledApp) -> [Leftover] {
        var collected: [Leftover] = []
        var seen = Set<URL>()

        func add(_ url: URL, _ kind: LeftoverKind, _ match: MatchStrength, userData: Bool,
                 admin: Bool = false, mustExist: Bool = true) {
            let key = url.standardizedFileURL
            guard !seen.contains(key) else { return }
            if mustExist && !exists(url) { return }
            seen.insert(key)
            let bytes = mustExist ? sizer.measure(url).bytes : 0
            collected.append(Leftover(
                url: url, kind: kind, match: match, mayContainUserData: userData,
                requiresAdmin: admin, bytes: bytes))
        }

        let lib = environment.userLibrary
        let sysLib = environment.systemLibrary
        func userDir(_ name: String) -> URL { lib.appending(path: name, directoryHint: .isDirectory) }

        // Bundle-ID based.
        if let b = app.bundleID, Self.isSafeComponent(b) {
            func child(_ dir: String, _ name: String) -> URL { userDir(dir).appending(path: name) }
            add(child("Caches", b), .caches, .exact, userData: false)
            add(child("Preferences", "\(b).plist"), .preferences, .exact, userData: false)
            for entry in entries(userDir("Preferences/ByHost"))
            where entry.hasPrefix("\(b).") && entry.hasSuffix(".plist") && entry.count > b.count + 7 {
                add(child("Preferences/ByHost", entry), .preferences, .exact, userData: false)
            }
            add(child("Saved Application State", "\(b).savedState"), .savedState, .exact, userData: false)
            add(child("HTTPStorages", b), .httpStorage, .exact, userData: false)
            add(child("HTTPStorages", "\(b).binarycookies"), .httpStorage, .exact, userData: false)
            add(child("WebKit", b), .webKit, .exact, userData: false)
            add(child("Logs", b), .logs, .exact, userData: false)
            add(child("Cookies", "\(b).binarycookies"), .cookies, .exact, userData: false)
            add(child("Application Support", b), .applicationSupport, .exact, userData: true)
            add(child("Containers", b), .container, .exact, userData: true)
        }

        if let t = app.teamID, Self.isSafeComponent(t) {
            let dir = userDir("Group Containers")
            for entry in entries(dir) where entry.hasPrefix("\(t).") {
                add(dir.appending(path: entry), .groupContainer, .exact, userData: true)
            }
        }

        // Name based.
        if Self.isSafeComponent(app.displayName) {
            let n = app.displayName
            add(userDir("Application Support").appending(path: n), .applicationSupport, .nameBased, userData: true)
            add(userDir("Caches").appending(path: n), .caches, .nameBased, userData: false)
            add(userDir("Logs").appending(path: n), .logs, .nameBased, userData: false)
        }

        // Launch agents / daemons / helpers.
        let launchDirs: [(URL, LeftoverKind, Bool)] = [
            (userDir("LaunchAgents"), .launchAgent, false),
            (sysLib.appending(path: "LaunchAgents", directoryHint: .isDirectory), .launchAgent, true),
            (sysLib.appending(path: "LaunchDaemons", directoryHint: .isDirectory), .launchDaemon, true),
        ]
        let validBundleID = app.bundleID.flatMap { Self.isSafeComponent($0) ? $0 : nil }
        for (dir, kind, admin) in launchDirs {
            for entry in entries(dir) where entry.hasSuffix(".plist") {
                let plistURL = dir.appending(path: entry)
                if launchPlist(plistURL, belongsTo: app, bundleID: validBundleID) {
                    add(plistURL, kind, .exact, userData: false, admin: admin)
                }
            }
        }
        if let b = validBundleID {
            let dir = sysLib.appending(path: "PrivilegedHelperTools", directoryHint: .isDirectory)
            for entry in entries(dir) where entry == b || entry.hasPrefix("\(b).") {
                add(dir.appending(path: entry), .privilegedHelper, .exact, userData: false, admin: true)
            }
        }

        // Package receipts. If pkgutil exits non-zero it simply knows no receipts for this app; if it
        // cannot be launched at all we also report none (command failures surface elsewhere).
        if let result = try? commands.run(Self.pkgutil, ["--file-info", app.url.path]), result.status == 0 {
            for line in result.stdout.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("pkgid:") else { continue }
                let id = line.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
                guard Self.isSafeComponent(id) else { continue }
                // Not checked for existence or measured: removal needs admin and happens in Plan 2.
                add(Self.receiptsDirectory.appending(path: "\(id).plist"), .packageReceipt, .exact,
                    userData: false, admin: true, mustExist: false)
            }
        }

        // Steam game data.
        if let id = app.steamAppID, Self.isSafeComponent(id) {
            let steamapps = userDir("Application Support").appending(path: "Steam/steamapps", directoryHint: .isDirectory)
            let manifest = steamapps.appending(path: "appmanifest_\(id).acf")
            if let text = try? String(contentsOf: manifest, encoding: .utf8),
               let installDir = Self.installDir(in: text), Self.isSafeComponent(installDir) {
                add(steamapps.appending(path: "common", directoryHint: .isDirectory).appending(path: installDir),
                    .steamGameData, .exact, userData: true)
                add(manifest, .steamGameData, .exact, userData: true)
            }
        }

        return collected
    }

    // MARK: - Helpers

    /// Rejects values that could escape their parent directory when used as a single path component.
    static func isSafeComponent(_ value: String) -> Bool {
        if value.isEmpty || value == "." || value == ".." { return false }
        return !value.contains { $0 == "/" || $0 == ":" || $0 == "\0" }
    }

    private func exists(_ url: URL) -> Bool {
        // lstat semantics: a dangling symlink still counts, and a symlink is never followed.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func entries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func launchPlist(_ url: URL, belongsTo app: InstalledApp, bundleID: String?) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return false }
        if let bundleID, let label = dict["Label"] as? String,
           label == bundleID || label.hasPrefix("\(bundleID).") { return true }
        var programs: [String] = []
        if let program = dict["Program"] as? String { programs.append(program) }
        if let args = dict["ProgramArguments"] as? [Any], let first = args.first as? String { programs.append(first) }
        return programs.contains { Self.path($0, isInside: app.url) }
    }

    private static func path(_ candidate: String, isInside root: URL) -> Bool {
        guard candidate.hasPrefix("/") else { return false }
        func inside(_ a: URL, _ b: URL) -> Bool {
            let c = a.standardizedFileURL.pathComponents
            let r = b.standardizedFileURL.pathComponents
            return c.count > r.count && Array(c.prefix(r.count)) == r
        }
        let url = URL(filePath: candidate)
        return inside(url, root) || inside(url.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    }

    private static func installDir(in manifest: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"installdir\"\\s+\"([^\"]*)\"") else { return nil }
        let range = NSRange(manifest.startIndex..., in: manifest)
        guard let m = regex.firstMatch(in: manifest, range: range),
              let r = Range(m.range(at: 1), in: manifest) else { return nil }
        return String(manifest[r])
    }
}
