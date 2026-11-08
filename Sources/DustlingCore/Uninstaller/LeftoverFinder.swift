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

    public func leftovers(for app: InstalledApp, among installed: [InstalledApp] = []) -> [Leftover] {
        leftoversWithIssues(for: app, among: installed).leftovers
    }

    public func leftoversWithIssues(
        for app: InstalledApp, among installed: [InstalledApp] = []
    ) -> (leftovers: [Leftover], issues: [ScanIssue]) {
        var collected: [Leftover] = []
        var issues: [ScanIssue] = []
        var seen = Set<URL>()
        var listings: [URL: [String]?] = [:]

        /// Lists a location directory once. Missing directories are silent; others report an issue.
        func listing(_ dir: URL) -> [String]? {
            if let cached = listings[dir] { return cached }
            var result: [String]?
            do {
                result = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            } catch {
                switch Self.classify(error) {
                case .missing: break
                case .denied: issues.append(.missingFullDiskAccess(dir))
                case .other: issues.append(.unreadable(dir))
                }
            }
            listings[dir] = .some(result)
            return result
        }

        func add(_ url: URL, _ kind: LeftoverKind, _ match: MatchStrength, userData: Bool,
                 admin: Bool = false, mustExist: Bool = true, note: String? = nil) {
            let key = url.standardizedFileURL
            guard !seen.contains(key) else { return }
            var bytes: UInt64 = 0
            if mustExist {
                guard listing(url.deletingLastPathComponent()) != nil, exists(url) else { return }
                let size = sizer.measure(url)
                bytes = size.bytes
                issues.append(contentsOf: size.unreadable.map { .unreadable($0) })
            }
            seen.insert(key)
            collected.append(Leftover(
                url: url, kind: kind, match: match, mayContainUserData: userData,
                requiresAdmin: admin, bytes: bytes, note: note))
        }

        let lib = environment.userLibrary
        let sysLib = environment.systemLibrary
        func userDir(_ name: String) -> URL { lib.appending(path: name, directoryHint: .isDirectory) }

        let validBundleID = app.bundleID.flatMap { Self.isSafeComponent($0) ? $0 : nil }
        // Longer bundle IDs of other installed apps that extend this one (e.g. Chrome vs Chrome Canary).
        let moreSpecific: [String] = validBundleID.map { b in
            installed.compactMap(\.bundleID).filter {
                $0 != b && $0.hasPrefix(b + ".") && Self.isSafeComponent($0)
            }
        } ?? []
        func belongsToMoreSpecific(_ name: String) -> Bool {
            moreSpecific.contains { name == $0 || name.hasPrefix($0 + ".") }
        }
        func claims(_ name: String, _ b: String) -> Bool {
            guard Self.matches(name, bundleID: b) else { return false }
            return !belongsToMoreSpecific(name)
        }

        // Bundle-ID based.
        if let b = validBundleID {
            func child(_ dir: String, _ name: String) -> URL { userDir(dir).appending(path: name) }
            add(child("Caches", b), .caches, .exact, userData: false)
            add(child("Preferences", "\(b).plist"), .preferences, .exact, userData: false)
            if Self.canPrefixMatch(b) {
                for entry in listing(userDir("Preferences/ByHost")) ?? []
                where Self.isByHost(entry, bundleID: b) && !belongsToMoreSpecific(entry) {
                    add(child("Preferences/ByHost", entry), .preferences, .exact, userData: false)
                }
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

        if let t = app.teamID, Self.isValidTeamID(t) {
            let shared = installed.contains { $0.url != app.url && $0.teamID == t }
            let dir = userDir("Group Containers")
            for entry in listing(dir) ?? [] where entry.hasPrefix("\(t).") {
                add(dir.appending(path: entry), .groupContainer, shared ? .nameBased : .exact, userData: true)
            }
        }

        // Name based. Skipped when another installed app has the same name: the folder could be its.
        let appPath = app.url.standardizedFileURL.path
        let nameIsShared = installed.contains {
            $0.url.standardizedFileURL.path != appPath && Self.fold($0.displayName) == Self.fold(app.displayName)
        }
        if !nameIsShared, Self.isSafeComponent(app.displayName) {
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
        for (dir, kind, admin) in launchDirs {
            for entry in listing(dir) ?? [] where entry.hasSuffix(".plist") {
                let plistURL = dir.appending(path: entry)
                let verdict = launchPlist(plistURL, belongsTo: app, bundleID: validBundleID, claims: claims)
                if verdict.unreadable { issues.append(.unreadable(plistURL)) }
                if verdict.matches {
                    add(plistURL, kind, .exact, userData: false, admin: admin)
                }
            }
        }
        if let b = validBundleID {
            let dir = sysLib.appending(path: "PrivilegedHelperTools", directoryHint: .isDirectory)
            for entry in listing(dir) ?? [] where claims(entry, b) {
                add(dir.appending(path: entry), .privilegedHelper, .exact, userData: false, admin: true)
            }
        }

        // Package receipts. A non-zero exit means pkgutil knows no receipts for this app (not an
        // error); a launch failure is reported as an issue.
        do {
            let result = try commands.run(Self.pkgutil, ["--file-info", app.url.path])
            if result.status == 0 {
                for line in result.stdout.split(whereSeparator: \.isNewline) {
                    guard line.hasPrefix("pkgid:") else { continue }
                    let id = line.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
                    guard Self.isSafeComponent(id) else { continue }
                    // Not checked for existence or measured: removal needs admin and happens in Plan 2.
                    add(Self.receiptsDirectory.appending(path: "\(id).plist"), .packageReceipt, .exact,
                        userData: false, admin: true, mustExist: false)
                }
            }
        } catch {
            issues.append(.commandFailed(command: "pkgutil --file-info", reason: "\(error)"))
        }

        // Steam game data. Other manifests are read to learn which install folders they declare, so a
        // folder shared by several games (e.g. "Half-Life 2") is never offered as this game's own.
        if let id = app.steamAppID, Self.isSafeComponent(id) {
            let steamapps = userDir("Application Support").appending(path: "Steam/steamapps", directoryHint: .isDirectory)
            let common = steamapps.appending(path: "common", directoryHint: .isDirectory)
            let manifestName = "appmanifest_\(id).acf"
            let manifest = steamapps.appending(path: manifestName)

            var otherOwners: [String: Int] = [:]   // folded installdir -> number of other manifests
            var othersVerified = false
            if let names = listing(steamapps) {
                othersVerified = true
                for name in names where name != manifestName && name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                    let other = steamapps.appending(path: name)
                    guard let text = try? String(contentsOf: other, encoding: .utf8) else {
                        issues.append(.unreadable(other))
                        othersVerified = false
                        continue
                    }
                    if let dir = Self.installDir(in: text) { otherOwners[Self.fold(dir), default: 0] += 1 }
                }
            }

            if exists(manifest) {
                if let text = try? String(contentsOf: manifest, encoding: .utf8) {
                    if let installDir = Self.installDir(in: text), Self.isSafeComponent(installDir) {
                        let sharers = otherOwners[Self.fold(installDir)] ?? 0
                        add(common.appending(path: installDir), .steamGameData, sharers > 0 ? .nameBased : .exact,
                            userData: true, note: sharers > 0 ? Self.sharedNote(sharers) : nil)
                        add(manifest, .steamGameData, .exact, userData: true)
                    }
                } else {
                    issues.append(.unreadable(manifest))
                }
            } else if othersVerified, !nameIsShared, Self.isSafeComponent(app.displayName),
                      otherOwners[Self.fold(app.displayName)] == nil {
                // No manifest (R27): offer steamapps/common/<name>, unchecked, only when no other game owns it.
                add(common.appending(path: app.displayName), .steamGameData, .nameBased, userData: true,
                    note: "matched by folder name, no Steam manifest found")
            }
        }

        return (collected, issues)
    }

    // MARK: - Helpers

    /// Rejects values that could escape their parent directory when used as a single path component.
    /// Scans unicode scalars: a `Character` check would let "/" combined with a following combining
    /// mark, ZWJ or variation selector slip through while path APIs still split on the raw slash.
    static func isSafeComponent(_ value: String) -> Bool {
        if value.isEmpty || value == "." || value == ".." { return false }
        return !value.unicodeScalars.contains { $0.value == 0x2F || $0.value == 0x3A || $0.value == 0 }
    }

    /// Case-insensitive key: APFS volumes are usually case-insensitive, so "Portal" and "portal" are
    /// the same folder. Over-matching here only ever withholds a leftover, never offers a wrong one.
    static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: nil)
    }

    static func sharedNote(_ others: Int) -> String {
        "shared with \(others) other Steam game" + (others == 1 ? "" : "s")
    }

    /// Prefix (dot-boundary) matching is only trusted for bundle IDs with at least 3 non-empty components.
    static func canPrefixMatch(_ bundleID: String) -> Bool {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
    }

    static func matches(_ name: String, bundleID b: String) -> Bool {
        name == b || (canPrefixMatch(b) && name.hasPrefix(b + "."))
    }

    /// `B.<segment without dots>.plist`
    static func isByHost(_ name: String, bundleID b: String) -> Bool {
        guard name.hasPrefix(b + "."), name.hasSuffix(".plist") else { return false }
        let start = name.index(name.startIndex, offsetBy: b.count + 1)
        let end = name.index(name.endIndex, offsetBy: -6)
        guard start < end else { return false }
        let middle = name[start..<end]
        return !middle.isEmpty && !middle.contains(".")
    }

    static func isValidTeamID(_ t: String) -> Bool {
        t.utf8.count == 10 && t.utf8.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) }
    }

    private enum ErrorClass { case missing, denied, other }

    private static func classify(_ error: any Error) -> ErrorClass {
        let ns = error as NSError
        var codes: [(String, Int)] = [(ns.domain, ns.code)]
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { codes.append((u.domain, u.code)) }
        for (domain, code) in codes {
            if domain == NSPOSIXErrorDomain {
                if code == Int(EPERM) || code == Int(EACCES) { return .denied }
                if code == Int(ENOENT) { return .missing }
            } else if domain == NSCocoaErrorDomain {
                if code == NSFileReadNoPermissionError { return .denied }
                if code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError { return .missing }
            }
        }
        return .other
    }

    private func exists(_ url: URL) -> Bool {
        // lstat semantics: a dangling symlink still counts, and a symlink is never followed.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func launchPlist(
        _ url: URL, belongsTo app: InstalledApp, bundleID: String?, claims: (String, String) -> Bool
    ) -> (matches: Bool, unreadable: Bool) {
        guard let data = try? Data(contentsOf: url) else { return (false, exists(url)) }
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return (false, false) }  // unparsable plists are ignored
        if let bundleID, let label = dict["Label"] as? String, claims(label, bundleID) { return (true, false) }
        var programs: [String] = []
        if let program = dict["Program"] as? String { programs.append(program) }
        if let args = dict["ProgramArguments"] as? [Any], let first = args.first as? String { programs.append(first) }
        return (programs.contains { Self.path($0, isInside: app.url) }, false)
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
