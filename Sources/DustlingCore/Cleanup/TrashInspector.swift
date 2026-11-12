import Foundation

/// One top-level item in a Trash location.
public struct TrashItem: Equatable, Sendable {
    public let url: URL
    public let size: SizeResult

    public init(url: URL, size: SizeResult) {
        self.url = url
        self.size = size
    }
}

/// What the Trash holds right now, as far as Dustling can see.
public struct TrashContents: Sendable {
    public var items: [TrashItem] = []
    public var size = SizeResult()
    public var issues: [ScanIssue] = []

    public init(items: [TrashItem] = [], size: SizeResult = SizeResult(), issues: [ScanIssue] = []) {
        self.items = items
        self.size = size
        self.issues = issues
    }
}

/// Sizes the Trash and empties it. Emptying is the one permanent delete in Dustling; callers must
/// confirm with the user first. Every child is reported as `.deleted` or `.failed`.
public struct TrashInspector: Sendable {
    private let environment: SystemEnvironment
    private let journal: RunJournal
    private let logger: RunLogger
    private let sizer: DirectorySizer
    private let inspect: @Sendable (URL) -> Kind
    private let includeExternalVolumes: Bool
    private let blocker: @Sendable (URL, uid_t) -> TrashBlocker?

    static let noAccessReason = "no access, grant Full Disk Access"

    /// `includeExternalVolumes: false` limits sizing and emptying to `~/.Trash`.
    public init(
        environment: SystemEnvironment, journal: RunJournal, logger: RunLogger, sizer: DirectorySizer,
        includeExternalVolumes: Bool = true
    ) {
        self.init(
            environment: environment, journal: journal, logger: logger, sizer: sizer,
            includeExternalVolumes: includeExternalVolumes, inspect: Self.lstatKind,
            blocker: { TrashUnlocker.blocker(of: $0, userID: $1) })
    }

    /// Test seam: replaces the `lstat` classification so error branches can be exercised.
    init(
        environment: SystemEnvironment, journal: RunJournal, logger: RunLogger, sizer: DirectorySizer,
        includeExternalVolumes: Bool = true,
        inspect: @escaping @Sendable (URL) -> Kind,
        blocker: @escaping @Sendable (URL, uid_t) -> TrashBlocker? = { TrashUnlocker.blocker(of: $0, userID: $1) }
    ) {
        self.blocker = blocker
        self.includeExternalVolumes = includeExternalVolumes
        self.inspect = inspect
        self.environment = environment
        self.journal = journal
        self.logger = logger
        self.sizer = sizer
    }

    private enum Failure { case denied, symlink, other(String) }

    private enum Discovered {
        case location(URL)
        case failure(URL, Failure)
    }

    /// `~/.Trash` plus `<volumes>/*/.Trashes/<uid>`, for those that exist.
    public func trashLocations() -> [URL] {
        discover().compactMap { if case .location(let url) = $0 { url } else { nil } }
    }

    /// Total size of the Trash. Locations or items that couldn't be read are in `unreadable`; use
    /// `sizeWithIssues()` to tell missing Full Disk Access from other failures.
    public func size() -> SizeResult {
        contents().size
    }

    /// Like `size()`, plus why each unreadable location or item couldn't be read: EPERM/EACCES become
    /// `.missingFullDiskAccess`, anything else `.unreadable`.
    public func sizeWithIssues() -> (size: SizeResult, issues: [ScanIssue]) {
        let found = contents()
        return (found.size, found.issues)
    }

    /// The top-level items in every Trash location, measured, plus the problems met on the way.
    public func contents() -> TrashContents {
        var found = TrashContents()
        func fail(_ url: URL, _ failure: Failure) {
            found.size.unreadable.append(url)
            found.issues.append(Self.issue(url, failure))
        }
        for item in discover() {
            switch item {
            case .failure(let url, let failure):
                fail(url, failure)
            case .location(let location):
                if let failure = verified(location) { fail(location, failure); continue }
                switch Self.list(location) {
                case .failure(let failure):
                    fail(location, failure)
                case .success(let children):
                    for child in children.sorted(by: { $0.path < $1.path }) {
                        let r = sizer.measure(child)
                        found.items.append(TrashItem(url: child, size: r))
                        found.size.bytes += r.bytes
                        found.size.fileCount += r.fileCount
                        found.size.unreadable += r.unreadable
                        found.issues += r.unreadable.map(Self.classifyUnreadable)
                    }
                }
            }
        }
        return found
    }

    /// Permanently deletes everything in the Trash. Journal/log failures are appended to the
    /// returned record as `<history>` / `<log>` entries.
    public func emptyTrash() -> RunRecord {
        let startedAt = Date()
        var entries: [JournalEntry] = []

        for item in discover() {
            switch item {
            case .failure(let url, let failure):
                entries.append(Self.failureEntry(url, failure))
            case .location(let location):
                if let failure = verified(location) {
                    entries.append(Self.failureEntry(location, failure))
                    continue
                }
                switch Self.list(location) {
                case .failure(let failure):
                    entries.append(Self.failureEntry(location, failure))
                case .success(let children):
                    for child in children {
                        let bytes = sizer.measure(child).bytes
                        let outcome: DeletionOutcome
                        outcome = remove(child)
                        entries.append(JournalEntry(
                            originalPath: child.path, bytes: bytes, outcome: outcome))
                    }
                }
            }
        }

        var record = RunRecord(startedAt: startedAt, kind: .emptyTrash, entries: entries, restorable: false)

        var journalSaved = true
        do { try journal.save(record) } catch {
            journalSaved = false
            record.entries.append(Self.marker("<history>", error))
        }
        do { try logger.write(record) } catch {
            record.entries.append(Self.marker("<log>", error))
            if journalSaved {
                do { try journal.save(record) } catch {
                    record.entries.append(Self.marker("<history>", error))
                }
            }
        }
        do { try journal.refreshRestorability() } catch {
            record.entries.append(Self.marker("<history>", error))
        }
        return record
    }

    /// Deletes one Trash child. When that fails, unlocks the user's own locked items (the user
    /// confirmed emptying) and tries once more; what still fails is explained, not guessed at.
    private func remove(_ child: URL) -> DeletionOutcome {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: child)   // never follows symlinks
            return .deleted
        } catch {
            _ = TrashUnlocker.unlockOwnItems(in: child, userID: environment.userID)
        }
        do {
            try fm.removeItem(at: child)
            return .deleted
        } catch {
            switch blocker(child, environment.userID) {
            case .otherOwner?: return .needsAdmin
            case .protectedByMacOS?: return .failed(reason: "protected by macOS")
            case nil: return .failed(reason: error.localizedDescription)
            }
        }
    }

    // MARK: - Discovery

    private func discover() -> [Discovered] {
        var found: [Discovered] = []
        check([environment.userTrash], reporting: environment.userTrash, into: &found)

        guard includeExternalVolumes else { return found }
        let volumes = environment.volumesDirectory
        switch Self.list(volumes) {
        case .failure(let failure):
            found.append(.failure(volumes, failure))
        case .success(let entries):
            for volume in entries.sorted(by: { $0.path < $1.path }) {
                // A symlinked volume (e.g. "Macintosh HD" -> /) is an alias, not a trash.
                let trashes = volume.appending(path: ".Trashes", directoryHint: .isDirectory)
                let trash = trashes.appending(path: "\(environment.userID)", directoryHint: .isDirectory)
                switch inspect(volume) {
                case .symlink, .missing: continue
                case .denied: found.append(.failure(trash, .denied)); continue
                case .other(let text): found.append(.failure(trash, .other(text))); continue
                case .directory, .nonDirectory: break
                }
                check([trashes, trash], reporting: trash, into: &found)
            }
        }
        return found
    }

    /// Re-verifies a location right before it is listed or deleted from.
    private func verified(_ location: URL) -> Failure? {
        var found: [Discovered] = []
        let trashes = location.deletingLastPathComponent()
        let isVolumeTrash = trashes.lastPathComponent == ".Trashes"
        check(isVolumeTrash ? [trashes, location] : [location], reporting: location, into: &found)
        if case .failure(_, let failure)? = found.first { return failure }
        return nil
    }

    /// Every component must be a real directory, never a symlink. A missing one means no location.
    private func check(_ components: [URL], reporting location: URL, into found: inout [Discovered]) {
        for component in components {
            switch inspect(component) {
            case .missing: return
            case .symlink: found.append(.failure(location, .symlink)); return
            case .denied: found.append(.failure(location, .denied)); return
            case .other(let text): found.append(.failure(location, .other(text))); return
            case .directory, .nonDirectory: continue
            }
        }
        found.append(.location(location))
    }

    enum Kind { case directory, nonDirectory, symlink, missing, denied, other(String) }

    static func lstatKind(_ url: URL) -> Kind {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case EPERM, EACCES: return .denied
            default: return .other(String(cString: strerror(errno)))
            }
        }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .directory
        default: return .nonDirectory
        }
    }

    private enum Listing { case success([URL]), failure(Failure) }

    private static func list(_ url: URL) -> Listing {
        do {
            return .success(try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
        } catch let error as NSError {
            var posix: Int32?
            if error.domain == NSPOSIXErrorDomain { posix = Int32(error.code) }
            if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
                posix = Int32(under.code)
            }
            if let posix, posix == EPERM || posix == EACCES { return .failure(.denied) }
            if posix == nil, error.code == NSFileReadNoPermissionError { return .failure(.denied) }
            return .failure(.other(error.localizedDescription))
        }
    }

    private static func issue(_ url: URL, _ failure: Failure) -> ScanIssue {
        switch failure {
        case .denied: .missingFullDiskAccess(url)
        case .symlink, .other: .unreadable(url)
        }
    }

    /// The sizer reports unreadable paths without a reason; ask the file system again for the errno.
    private static func classifyUnreadable(_ url: URL) -> ScanIssue {
        let path = url.path(percentEncoded: false)
        func denied(_ code: Int32) -> Bool { code == EPERM || code == EACCES }
        var st = stat()
        if lstat(path, &st) != 0 {
            return denied(errno) ? .missingFullDiskAccess(url) : .unreadable(url)
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            guard let dir = opendir(path) else { return denied(errno) ? .missingFullDiskAccess(url) : .unreadable(url) }
            closedir(dir)
        } else if (st.st_mode & S_IFMT) == S_IFREG {
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return denied(errno) ? .missingFullDiskAccess(url) : .unreadable(url) }
            close(fd)
        }
        return .unreadable(url)
    }

    private static func failureEntry(_ url: URL, _ failure: Failure) -> JournalEntry {
        let reason: String
        switch failure {
        case .denied: reason = noAccessReason
        case .symlink: reason = "trash location is a symbolic link, not emptied"
        case .other(let text): reason = text
        }
        return JournalEntry(originalPath: url.path, bytes: 0, outcome: .failed(reason: reason))
    }

    private static func marker(_ name: String, _ error: Error) -> JournalEntry {
        JournalEntry(originalPath: name, bytes: 0, outcome: .failed(reason: error.localizedDescription))
    }
}
