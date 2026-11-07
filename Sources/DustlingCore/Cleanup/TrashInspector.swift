import Foundation

/// Sizes the Trash and empties it. Emptying is the one permanent delete in Dustling; callers must
/// confirm with the user first. Every child is reported as `.deleted` or `.failed`.
public struct TrashInspector: Sendable {
    private let environment: SystemEnvironment
    private let journal: RunJournal
    private let logger: RunLogger
    private let sizer: DirectorySizer
    private let inspect: @Sendable (URL) -> Kind

    static let noAccessReason = "no access, grant Full Disk Access"

    public init(environment: SystemEnvironment, journal: RunJournal, logger: RunLogger, sizer: DirectorySizer) {
        self.init(environment: environment, journal: journal, logger: logger, sizer: sizer, inspect: Self.lstatKind)
    }

    /// Test seam: replaces the `lstat` classification so error branches can be exercised.
    init(
        environment: SystemEnvironment, journal: RunJournal, logger: RunLogger, sizer: DirectorySizer,
        inspect: @escaping @Sendable (URL) -> Kind
    ) {
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

    public func size() -> SizeResult {
        var total = SizeResult()
        for item in discover() {
            switch item {
            case .failure(let url, _):
                total.unreadable.append(url)
            case .location(let location):
                if verified(location) != nil { total.unreadable.append(location); continue }
                switch Self.list(location) {
                case .failure:
                    total.unreadable.append(location)
                case .success(let children):
                    for child in children {
                        let r = sizer.measure(child)
                        total.bytes += r.bytes
                        total.fileCount += r.fileCount
                        total.unreadable += r.unreadable
                    }
                }
            }
        }
        return total
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
                        do {
                            try FileManager.default.removeItem(at: child)   // never follows symlinks
                            outcome = .deleted
                        } catch {
                            outcome = .failed(reason: error.localizedDescription)
                        }
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

    // MARK: - Discovery

    private func discover() -> [Discovered] {
        var found: [Discovered] = []
        check([environment.userTrash], reporting: environment.userTrash, into: &found)

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
