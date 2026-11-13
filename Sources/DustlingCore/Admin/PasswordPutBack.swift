import Foundation

/// Where Put back may use the Mac password.
///
/// A run's History file is a plain file Dustling's user can write, so neither the Trash path nor the
/// original path in it is trusted on its own: another program running as the user could write a run
/// whose Put back has root rename that program's own file into a system folder (say
/// `/private/etc/zshenv`, which root's shells read). Put back asks for the password only for an entry
/// shaped like what Dustling itself moves with the password:
/// - the item is directly in a Trash folder (`~/.Trash`, or `<volume>/.Trashes/<uid>`);
/// - it goes back directly into a folder Dustling moves from with the password for that kind of run,
///   which the guard (`ProtectedPaths`) allows. An uninstall: an app (`.app`) in an application folder
///   or in a folder inside one, as deep as `AppScout` looks and never inside another app, or a leftover
///   in one of `LeftoverFinder.locationDirectories`. A junk clean: an item in one of the junk
///   categories' own folders (`CleanupRunner` moves any item that needs admin, whatever its
///   category), except System caches and logs, which Dustling never cleans. Nothing for an Empty
///   Trash or a startup change (Startup items never use the password);
/// - into the system's launch and helper folders (`/Library/LaunchAgents`, `LaunchDaemons`,
///   `PrivilegedHelperTools`), only an item recorded as root's with no other hard link: those
///   folders only hold root's items, and launchd runs a helper there as root whoever owns it;
/// - the folder is reached from the home folder, or from the system folder it is in (`/Library`, an
///   application folder outside home), one component at a time through descriptors without following
///   a link (another program could plant one, such as `~/Library` → `/Library`, so that the path leads
///   elsewhere). The root script then requires that very folder (`AdminStep.expectedFolder`).
enum PasswordPutBack {
    /// A Put back the password may do: the item in the Trash, where it goes, both written the
    /// environment's way (`environmentForm`, so the root script's planning sees the same Trash), and
    /// the destination folder as found by walking down without links (`AdminStep.expectedFolder`).
    struct Target: Equatable {
        let from: URL
        let to: URL
        let folder: ItemIdentity
    }

    /// Where the item goes back with the password, when Put back may use it for this entry (see
    /// above); nil when it may not. `recordedOwner` is who owned the item when it moved to the Trash
    /// (the journal's `trashedIdentity.owner`).
    static func target(
        trashed: String, original: String, recordedOwner: uid_t, kind: RunKind, environment: SystemEnvironment
    ) -> Target? {
        let trashed = environmentForm(trashed, environment: environment)
        let original = environmentForm(original, environment: environment)
        guard let source = AdminPath(URL(fileURLWithPath: trashed)), !source.name.isEmpty,
              AdminPlanning.trash(of: environment)(source.folder),
              let destination = AdminPath(URL(fileURLWithPath: original)), !destination.name.isEmpty,
              let root = allowedRoot(of: destination, kind: kind, environment: environment),
              ProtectedPaths(environment: environment)
                .verdict(for: URL(fileURLWithPath: destination.full), allowedRoots: [root]) == .allowed
        else { return nil }
        if launchAndHelperFolders(environment).contains(destination.folder) {
            var info = stat()
            guard recordedOwner == 0, lstat(source.full, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR || info.st_nlink <= 1
            else { return nil }
        }
        guard let folder = folderWithoutLinks(destination.folder, environment: environment) else { return nil }
        return Target(from: URL(fileURLWithPath: source.full), to: URL(fileURLWithPath: destination.full), folder: folder)
    }

    /// The root the destination belongs to (for the guard's verdict), when its folder is one Dustling
    /// moves from with the password for `kind`.
    static func allowedRoot(of destination: AdminPath, kind: RunKind, environment: SystemEnvironment) -> URL? {
        switch kind {
        case .uninstall:
            if let location = LeftoverFinder.locationDirectories(environment)
                .first(where: { path($0) == destination.folder }) {
                return location
            }
            return applicationFolder(of: destination, environment: environment)
        case .junkClean:
            let folder = URL(fileURLWithPath: destination.folder, isDirectory: true)
            let declared = JunkCatalog.standard(environment).contains {
                $0.id != .trash && !$0.isNeverCleaned && $0.isDeclaredRoot(folder)
            }
            return declared ? folder : nil
        case .emptyTrash, .startupChange:
            return nil
        }
    }

    /// The application folder an app at `destination` is in: `<application folder>/<name>.app`, or up
    /// to `AppScout.maxDepth - 1` folders deeper, none of them an app itself.
    private static func applicationFolder(of destination: AdminPath, environment: SystemEnvironment) -> URL? {
        guard isApp(destination.name) else { return nil }
        for folder in environment.applicationDirectories {
            let base = path(folder)
            guard let rest = components(of: destination.folder, below: base) else { continue }
            if rest.count < AppScout.maxDepth, !rest.contains(where: isApp) { return folder }
        }
        return nil
    }

    private static func isApp(_ name: String) -> Bool {
        name.count > 4 && name.lowercased().hasSuffix(".app")
    }

    /// `/Library/LaunchAgents`, `/Library/LaunchDaemons` and `/Library/PrivilegedHelperTools`.
    private static func launchAndHelperFolders(_ environment: SystemEnvironment) -> Set<String> {
        Set(["LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"].map {
            path(environment.systemLibrary.appending(path: $0, directoryHint: .isDirectory))
        })
    }

    /// The identity of the folder at `folder`, opened from a folder no program running as the user
    /// can replace (the home folder for anything in it; otherwise the system library or an application
    /// folder outside home, whichever holds it, longest first), then one component at a time with
    /// `openat(O_NOFOLLOW)`. Nil when `folder` is in none of them, or a component is a link, missing
    /// or not a folder.
    static func folderWithoutLinks(_ folder: String, environment: SystemEnvironment) -> ItemIdentity? {
        let home = path(environment.home)
        var anchor: String?
        var rest: [String]?
        if let below = components(of: folder, below: home) {
            (anchor, rest) = (home, below)
        } else {
            let system = ([environment.systemLibrary] + environment.applicationDirectories).map(path)
                .filter { components(of: $0, below: home) == nil }
                .sorted { $0.utf8.count > $1.utf8.count }
            for base in system {
                if let below = components(of: folder, below: base) {
                    (anchor, rest) = (base, below)
                    break
                }
            }
        }
        guard let anchor, let rest else { return nil }
        var fd = open(anchor, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for component in rest {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return ItemIdentity(info)
    }

    /// `path` as the environment names its folders: when it starts with the real path of the home
    /// folder, the system library, the volumes folder or an application folder (which a listing may
    /// hand back, such as `/private/var/…` for `/var/…`), that start is written the environment's way,
    /// so the checks above compare like with like. Only the environment's own folders are resolved,
    /// never anything from `path`.
    static func environmentForm(_ path: String, environment: SystemEnvironment) -> String {
        let path = AdminPath.trimmingTrailingSlashes(path)
        let bases = ([environment.home, environment.systemLibrary, environment.volumesDirectory]
            + environment.applicationDirectories).map(Self.path)
        for base in bases {
            guard let real = ProtectedPaths.realpathString(base), real != base,
                  let rest = components(of: path, below: real)
            else { continue }
            return rest.isEmpty ? base : base + "/" + rest.joined(separator: "/")
        }
        return path
    }

    /// The components of `path` below `base` (empty when they are the same), compared on UTF-8
    /// bytes; nil when `path` isn't `base` or inside it, or a component is empty, `.` or `..`.
    private static func components(of path: String, below base: String) -> [String]? {
        let bytes = Array(path.utf8)
        let prefix = Array(base.utf8)
        guard bytes.starts(with: prefix) else { return nil }
        let tail = bytes.dropFirst(prefix.count)
        if tail.isEmpty { return [] }
        guard tail.first == UInt8(ascii: "/") || prefix.last == UInt8(ascii: "/") else { return nil }
        let parts = tail.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0.elementsEqual([UInt8(ascii: ".")]) || $0.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")]) })
        else { return nil }
        return parts.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func path(_ url: URL) -> String {
        AdminPath.trimmingTrailingSlashes(url.path(percentEncoded: false))
    }
}
