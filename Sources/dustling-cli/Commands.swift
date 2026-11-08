import DustlingAppModel
import DustlingCore
import AppKit
import Foundation

/// One function per CLI command. Each returns the process exit code.
enum Commands {
    private static let env = SystemEnvironment.current
    private static let commands = ProcessCommandRunner()

    /// The CLI has no settings yet: defaults. Catalog, cleaning and uninstalling all derive from this one value.
    /// The app's scan settings (exclusions, skip-recent, external Trash) when the app has saved
    /// them, so the CLI never touches what the app was told to leave alone; plain defaults otherwise.
    private static let options = AppSettings.savedScanOptions(in: UserDefaults(suiteName: AppSettings.appDefaultsDomain))

    private static var journal: RunJournal { RunJournal(directory: env.historyDirectory) }

    private static func makeRunner() -> CleanupRunner {
        CleanupRunner(
            mover: TrashMover(backend: SystemTrashBackend(), protectedPaths: options.protectedPaths(environment: env)),
            journal: journal, logger: RunLogger(directory: env.logsDirectory), sizer: DirectorySizer())
    }

    private static func runningBundleIDs() -> Set<String> {
        // The scanner uses this to flag caches of apps that are open right now.
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private static func makeScanner() -> JunkScanner {
        JunkScanner(environment: env, runningBundleIDs: { runningBundleIDs() })
    }

    // MARK: doctor

    static func doctor() async -> Int32 {
        let report = HealthCheck(environment: env, commands: commands).run()
        switch report.fullDiskAccess {
        case .granted: print("Full Disk Access: on")
        case .denied: print("Full Disk Access: off")
        case .unknown: print("Full Disk Access: unknown")
        }
        if let storage = report.storage {
            print("Disk: \(Format.bytes(storage.totalBytes)) total, \(Format.bytes(storage.availableBytes)) free")
            let purgeable = max(0, storage.availableForImportantUsage - storage.availableBytes)
            if purgeable > 1_000_000_000 {
                print("Purgeable: \(Format.bytes(purgeable)) (macOS frees this by itself when it needs room)")
            }
            print("Time Machine local snapshots: \(storage.localSnapshotCount)")
        } else {
            print("Disk: unavailable")
        }
        if report.problems.isEmpty {
            print("No problems found.")
            return 0
        }
        print("Problems:")
        for problem in report.problems { print("  ! \(problem)") }
        if report.fullDiskAccess != .granted {
            print("Open System Settings > Privacy & Security > Full Disk Access, or run: open \"\(FullDiskAccessProbe.settingsURL.absoluteString)\"")
        }
        return 1
    }

    // MARK: scan

    static func scan() async -> Int32 {
        print("Scanning...")
        let results = await makeScanner().scan(JunkCatalog.standard(env, options: options)) { scan in
            printCategory(scan)
        }
        if results.contains(where: \.stopped) {
            Format.printError("Scan stopped before it finished; the numbers above are partial.")
            return 1
        }
        // Separate totals on purpose: they mean different things and are never added up.
        let totals = ScanTotals(results)
        print("")
        print("Cleanable by default: \(Format.total(totals.cleanableByDefault))  (dustling-cli clean)")
        if totals.skippedInUse > 0 {
            print("  \(Format.bytes(totals.skippedInUse)) of the default categories belongs to apps that are open "
                + "right now and will be skipped")
        }
        print("Review items: \(Format.total(totals.review))  (dustling-cli clean --include <categoryID>)")
        print("Needs admin: \(Format.total(totals.needsAdmin))  (not touched by this version)")
        print("Trash: \(Format.total(totals.trash))  (dustling-cli empty-trash)")
        return 0
    }

    private static func printCategory(_ scan: CategoryScan) {
        let id = scan.category.id.rawValue
        print("\(scan.category.title) (\(id))\(Format.tag(for: scan.category.selection)): "
            + Format.categorySummary(scan)
            + (scan.stopped ? " [scan stopped]" : "")
            + (scan.category.requiresAdmin ? " [needs admin]" : ""))
        Format.printIssues(scan.issues)
    }

    // MARK: clean

    static func clean(_ args: [String]) async -> Int32 {
        var include: [JunkCategoryID] = []
        var assumeYes = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--yes": assumeYes = true
            case "--include":
                index += 1
                // Accept several ids after one --include, until the next flag.
                var consumed = 0
                while index < args.count, !args[index].hasPrefix("--") {
                    guard let id = JunkCategoryID(rawValue: args[index]) else {
                        Format.printError("Unknown category: \(args[index])")
                        Format.printError("Valid ids: " + JunkCategoryID.allCases.map(\.rawValue).joined(separator: ", "))
                        return 1
                    }
                    include.append(id)
                    consumed += 1
                    index += 1
                }
                if consumed == 0 { Format.printError("--include needs a category id."); return 1 }
                continue
            default:
                Format.printError("Unknown option: \(args[index])")
                return 1
            }
            index += 1
        }
        if include.contains(.trash) {
            Format.printError("The Trash can't be cleaned by moving it. Use: dustling-cli empty-trash")
            return 1
        }

        print("Scanning...")
        let results = await makeScanner().scan(JunkCatalog.standard(env, options: options)) { _ in }
        if results.contains(where: \.stopped) {
            Format.printError("Scan stopped before it finished; nothing was cleaned.")
            return 1
        }

        let chosen = results.filter { scan in
            scan.category.id != .trash
                && (scan.category.selection == .preselected || include.contains(scan.category.id))
        }
        for scan in results { Format.printIssues(scan.issues) }

        // Items of apps that are open right now are left alone; admin-only categories are never attempted.
        var urls: [URL] = []
        var extra: [JournalEntry] = []
        var shownBytes: UInt64 = 0
        var roots = Set<URL>()
        for scan in chosen {
            let inUse = scan.items.filter { $0.inUseByBundleID != nil }
            let usable = scan.items.filter { $0.inUseByBundleID == nil }
            print("  \(scan.category.title) (\(scan.category.id.rawValue)): " + Format.categorySummary(scan))
            // Review categories are only cleaned because the user asked: show every item they approve.
            if scan.category.selection == .review {
                let showsAccess = scan.category.roots.contains { $0.lastPathComponent == "Downloads" }
                for item in usable {
                    print("    \(Format.bytes(item.bytes))  \(Format.path(item.url))"
                        + (showsAccess ? "  (last opened \(Format.lastOpened(item.url)))" : ""))
                }
            }
            for item in inUse {
                Format.printWarning("Skipping \(item.url.lastPathComponent): the app is open right now")
                extra.append(JournalEntry(
                    originalPath: item.url.path(percentEncoded: false), bytes: item.bytes,
                    outcome: .skipped(reason: "in use by \(item.inUseByBundleID ?? "a running app")")))
            }
            if scan.category.requiresAdmin {
                for item in usable {
                    extra.append(JournalEntry(
                        originalPath: item.url.path(percentEncoded: false), bytes: item.bytes, outcome: .needsAdmin))
                }
                if !usable.isEmpty {
                    Format.printWarning("\(scan.category.title) needs admin rights and will not be touched")
                }
            } else {
                // The guard's allowed roots are the folders the scan really resolved for this category
                // (its fixed roots, or an expansion such as Containers/<id>/Data/Library/Caches).
                // Every item is a direct child of one of them; anything else is not touched.
                for item in usable {
                    let parent = item.url.deletingLastPathComponent()
                    if scan.category.isDeclaredRoot(parent) {
                        urls.append(item.url)
                        shownBytes += item.bytes
                        roots.insert(parent)
                    } else {
                        extra.append(JournalEntry(
                            originalPath: item.url.path(percentEncoded: false), bytes: item.bytes,
                            outcome: .skipped(reason: "outside the cleanup area")))
                    }
                }
            }
        }
        guard !urls.isEmpty else {
            print("Nothing to move to the Trash.")
            return extra.contains { $0.outcome == .needsAdmin } ? 2 : 0
        }

        guard Format.confirm(
            "Move \(Format.plural(urls.count, "item")) (\(Format.bytes(shownBytes))) to Trash? [y/N]", assumeYes: assumeYes)
        else {
            print("Cancelled.")
            return 0
        }

        let record = await makeRunner().run(
            urls, kind: .junkClean, allowedRoots: Array(roots), extraEntries: extra) { _, _ in }
        Format.printEntries(record)
        let code = Format.printTotals(record)
        if record.bytesMovedToTrash > 0 {
            print("Space is freed when the Trash is emptied: dustling-cli empty-trash")
        }
        return code
    }

    // MARK: apps

    private static func sortedApps() -> (apps: [InstalledApp], unreadable: [URL]) {
        let found = AppScout(environment: env).discoverWithIssues()
        let apps = found.apps.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
        return (apps, found.unreadable)
    }

    static func apps() -> Int32 {
        let found = sortedApps()
        for (offset, app) in found.apps.enumerated() {
            let number = String(offset + 1).leftPadded(to: 3)
            print("\(number)  \(app.displayName)  \(Format.bytes(app.bytes))  \(Format.path(app.url))"
                + Format.linkNote(app))
        }
        if found.apps.isEmpty { print("No apps found.") }
        Format.printIssues(found.unreadable.map { .unreadable($0) })
        return 0
    }

    // MARK: uninstall

    static func uninstall(_ args: [String]) async -> Int32 {
        var query: String?
        var includeAll = false
        var assumeYes = false
        for arg in args {
            switch arg {
            case "--all": includeAll = true
            case "--yes": assumeYes = true
            default:
                if arg.hasPrefix("--") { Format.printError("Unknown option: \(arg)"); return 1 }
                if query != nil { Format.printError("Give one app name or number (quote names with spaces)."); return 1 }
                query = arg
            }
        }
        guard let query else {
            Format.printError("Usage: dustling-cli uninstall <name|number> [--all]")
            return 1
        }

        let found = sortedApps()
        Format.printIssues(found.unreadable.map { .unreadable($0) })
        let app: InstalledApp
        switch resolve(query, in: found.apps) {
        case .success(let match): app = match
        case .failure(let message):
            Format.printError(message)
            return 1
        }

        // Other apps help the finder decide what a leftover belongs to. Exclude the target itself and
        // anything nested inside its bundle (helper apps), which would otherwise claim its files.
        let targetPath = app.url.standardizedFileURL.path(percentEncoded: false)
        let others = found.apps.filter { other in
            let path = other.url.standardizedFileURL.path(percentEncoded: false)
            return path != targetPath && !path.hasPrefix(targetPath.hasSuffix("/") ? targetPath : targetPath + "/")
        }
        let finder = LeftoverFinder(environment: env, sizer: DirectorySizer(), commands: commands)
        let result = finder.leftoversWithIssues(for: app, among: others)
        Format.printIssues(result.issues)

        print("\(app.displayName)  \(Format.bytes(app.bytes))  \(Format.path(app.url))" + Format.linkNote(app))
        // For a symlinked app only the link goes; the real app and its files stay, so nothing is
        // preselected (the user can still opt in with --all).
        let isLink = app.linkTarget != nil
        let preselected = { (leftover: Leftover) in !isLink && leftover.preselected }
        let selected = includeAll ? result.leftovers : result.leftovers.filter(preselected)
        if isLink {
            Format.printWarning("\(Format.path(app.url)) is a link: only the link will be removed, the app stays at "
                + "\(Format.path(app.linkTarget!)). Its files below belong to that app, so none are checked.")
        }
        for leftover in result.leftovers {
            let mark = (includeAll || preselected(leftover)) ? "[x]" : "[ ]"
            var notes = ""
            if let note = leftover.note { notes += "  (\(note))" }
            if leftover.mayContainUserData { notes += "  (may contain your data)" }
            if leftover.requiresAdmin { notes += "  (needs admin, will not be touched)" }
            print("  \(mark) \(Format.bytes(leftover.bytes))  \(Format.path(leftover.url))\(notes)")
        }
        if result.leftovers.isEmpty { print("  No leftovers found.") }
        if includeAll {
            for leftover in selected where leftover.mayContainUserData {
                Format.printWarning("--all includes \(Format.path(leftover.url)), which may contain your data")
            }
        } else if result.leftovers.contains(where: { !preselected($0) }) {
            print("Unchecked items are kept. Add --all to move them too.")
        }

        let movable = selected.filter { !$0.requiresAdmin }
        // Removing a link frees (next to) nothing, so the target's size isn't counted.
        let total = (isLink ? 0 : app.bytes) + movable.reduce(0) { $0 + $1.bytes }
        let count = 1 + movable.count
        let prompt = "Move \(Format.plural(count, "item")) (\(Format.bytes(total))) to Trash?"
            + (isLink ? " The link is removed, not the app." : "") + " [y/N]"
        guard Format.confirm(prompt, assumeYes: assumeYes) else {
            print("Cancelled.")
            return 0
        }

        do {
            let record = try await Uninstaller(
                runner: makeRunner(), commands: commands, running: WorkspaceRunningApps(), environment: env
            ).uninstall(app, leftovers: selected) { _, _ in }
            Format.printEntries(record)
            let code = Format.printTotals(record)
            if record.bytesMovedToTrash > 0 {
                print("Space is freed when the Trash is emptied: dustling-cli empty-trash")
            }
            return code
        } catch UninstallError.appIsRunning(let name) {
            Format.printError("\(name) is running. Quit it first, then try again.")
            return 1
        } catch {
            Format.printError("Uninstall failed: \(error.localizedDescription)")
            return 1
        }
    }

    private enum Resolution { case success(InstalledApp), failure(String) }

    private static func resolve(_ query: String, in apps: [InstalledApp]) -> Resolution {
        if let number = Int(query) {
            guard apps.indices.contains(number - 1) else {
                return .failure("No app number \(number). Run: dustling-cli apps")
            }
            return .success(apps[number - 1])
        }
        let lowered = query.lowercased()
        let exact = apps.filter { $0.displayName.lowercased() == lowered }
        if exact.count == 1 { return .success(exact[0]) }
        let candidates = exact.isEmpty ? apps.filter { $0.displayName.lowercased().contains(lowered) } : exact
        switch candidates.count {
        case 0: return .failure("No app matches \"\(query)\". Run: dustling-cli apps")
        case 1: return .success(candidates[0])
        default:
            let list = candidates.map { "  \($0.displayName)  \(Format.path($0.url))" }.joined(separator: "\n")
            return .failure("\"\(query)\" matches more than one app. Use its number from `dustling-cli apps`:\n\(list)")
        }
    }

    // MARK: startup

    static func startup(_ args: [String]) -> Int32 {
        let apps = AppScout(environment: env).discoverWithIssues().apps
        let scanned = StartupItemScanner(environment: env, commands: commands, apps: apps).scanWithIssues()
        let scanner = StartupItemScanner(environment: env, commands: commands, apps: apps)

        guard let action = args.first else {
            for item in scanned.items.sorted(by: { $0.label.lowercased() < $1.label.lowercased() }) {
                let state = item.isEnabled ? "on " : "off"
                let owner = item.ownerAppName.map { "  (\($0))" } ?? ""
                let note = item.managedInSystemSettingsOnly ? "  [System Settings only]" : ""
                print("\(state)  \(item.scope.rawValue.leftPadded(to: 11))  \(item.label)\(owner)\(note)")
            }
            if scanned.items.isEmpty { print("No startup items found.") }
            Format.printIssues(scanned.issues)
            return 0
        }

        guard action == "disable" || action == "enable" else {
            Format.printError("Usage: dustling-cli startup [disable|enable <label>]")
            return 1
        }
        let rest = args.dropFirst().filter { $0 != "--yes" }
        guard rest.count == 1, let label = rest.first else {
            Format.printError("Usage: dustling-cli startup \(action) <label>")
            return 1
        }
        guard let item = scanned.items.first(where: { $0.label == label }) else {
            Format.printError("No startup item with the label \"\(label)\". Run: dustling-cli startup")
            return 1
        }
        let enable = action == "enable"
        guard Format.confirm("\(enable ? "Enable" : "Disable") \(item.label)? [y/N]", assumeYes: args.contains("--yes")) else {
            print("Cancelled.")
            return 0
        }
        let recorder = StartupChangeRecorder(
            scanner: scanner, journal: journal, logger: RunLogger(directory: env.logsDirectory))
        let record = recorder.setEnabled(item, enable)
        guard let outcome = record.entries.first?.outcome else { return 2 }
        print("\(item.label): \(outcome.label)")
        // The change itself is done; say so if it could not be written to History or the log.
        for extra in record.entries.dropFirst() {
            if case .failed(let reason) = extra.outcome {
                Format.printWarning("Couldn't write to \(extra.originalPath == "<history>" ? "History" : "the log"): \(reason)")
            }
        }
        return Format.isProblem(outcome) ? 2 : 0
    }

    // MARK: history / restore

    static func history() -> Int32 {
        let journal = self.journal
        // Bring the "restorable" markers up to date first (the Trash may have been emptied since).
        do { try journal.refreshRestorability() } catch {
            Format.printWarning("Couldn't update which runs can be restored: \(error.localizedDescription)")
        }
        let runs: [RunRecord]
        do { runs = try journal.all() } catch {
            Format.printError("Couldn't read history: \(error.localizedDescription)")
            return 1
        }
        for run in runs.sorted(by: { $0.startedAt > $1.startedAt }) {
            let id = String(run.id.uuidString.lowercased().prefix(8))
            var line = "\(id)  \(Format.date(run.startedAt))  \(Format.kind(run.kind))  "
                + "\(Format.plural(run.entries.count, "entry", "entries")), \(Format.bytes(run.bytesMovedToTrash)) moved to Trash"
            if run.failedCount > 0 { line += ", \(run.failedCount) failed" }
            if run.needsAdminCount > 0 { line += ", \(run.needsAdminCount) need admin" }
            if run.restorable { line += "  restorable" }
            print(line)
        }
        if runs.isEmpty { print("No runs yet.") }
        let bad = journal.unreadableRecords()
        for url in bad { Format.printWarning("Couldn't read history record \(url.path(percentEncoded: false))") }
        return 0
    }

    private static let notRestorableMessage =
        "This run can't be restored: its items were already put back or are no longer in the Trash."

    static func restore(_ args: [String]) -> Int32 {
        var prefix: String?
        var path: String?
        var assumeYes = false
        let usage = "Usage: dustling-cli restore <run-id-prefix> [--path <p>] [--yes]"
        var index = 0
        while index < args.count {
            if args[index] == "--path" {
                index += 1
                guard index < args.count else { Format.printError("--path needs a value."); return 1 }
                path = args[index]
            } else if args[index] == "--yes" {
                assumeYes = true
            } else if args[index].hasPrefix("--") {
                Format.printError("Unknown option: \(args[index])")
                return 1
            } else if prefix == nil {
                prefix = args[index].lowercased()
            } else {
                Format.printError(usage)
                return 1
            }
            index += 1
        }
        guard let prefix, !prefix.isEmpty else {
            Format.printError(usage)
            return 1
        }

        let journal = self.journal
        do { try journal.refreshRestorability() } catch {
            Format.printWarning("Couldn't update which runs can be restored: \(error.localizedDescription)")
        }
        let runs: [RunRecord]
        do { runs = try journal.all() } catch {
            Format.printError("Couldn't read history: \(error.localizedDescription)")
            return 1
        }
        let matches = runs.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        guard matches.count == 1, let run = matches.first else {
            Format.printError(matches.isEmpty
                ? "No run starts with \"\(prefix)\". Run: dustling-cli history"
                : "More than one run starts with \"\(prefix)\". Type more characters.")
            return 1
        }

        // The entries in scope: all of the run's, or the ones with the given path.
        var scope = run.entries.filter { !$0.originalPath.hasPrefix("<") }   // skip <history>/<log> markers
        if let path {
            let wanted = Format.normalizedPath(path)
            scope = scope.filter { Format.normalizedPath($0.originalPath) == wanted }
            guard !scope.isEmpty else {
                Format.printError("No entry with that path in this run.")
                return 1
            }
        }
        let candidates = scope.filter { RunJournal.isRestorable($0) }
        guard !candidates.isEmpty else {
            Format.printError(path == nil
                ? notRestorableMessage
                : "That item can't be restored: it was already put back, never reached the Trash, "
                    + "or is no longer in the Trash.")
            return 1
        }

        // Show exactly what will be put back, and only restore what was shown.
        print("These items will be put back where they were:")
        for entry in candidates {
            print("  \(Format.bytes(entry.bytes))  \(entry.originalPath)")
        }
        for entry in scope where !entry.restored && !RunJournal.isRestorable(entry) {
            if case .movedToTrash = entry.outcome {
                print("  can't be put back, no longer in the Trash: \(entry.originalPath)")
            }
        }
        let total = candidates.reduce(UInt64(0)) { $0 + $1.bytes }
        guard Format.confirm(
            "Put back \(Format.plural(candidates.count, "item")) (\(Format.bytes(total))) from the Trash? [y/N]",
            assumeYes: assumeYes)
        else {
            print("Cancelled.")
            return 0
        }

        func report(_ outcomes: [RestoreOutcome]) -> Int32 {
            var code: Int32 = 0
            for outcome in outcomes {
                switch outcome {
                case .restored(let p): print("  \(p): restored")
                case .conflict(let p): print("  \(p): not restored, something is already there"); code = 2
                case .missingFromTrash(let p): print("  \(p): not restored, it is no longer in the Trash"); code = 2
                case .failed(let p, let reason): print("  \(p): failed: \(reason)"); code = 2
                }
            }
            if outcomes.isEmpty { print("Nothing was restored.") }
            return code
        }

        do {
            return report(try journal.restore(runID: run.id, paths: Set(candidates.map(\.originalPath))))
        } catch RunJournalError.saveFailed(let outcomes, let underlying) {
            // An empty list means the history couldn't be updated before anything was moved.
            guard !outcomes.isEmpty else {
                Format.printError("The history couldn't be updated, so nothing was restored: "
                    + underlying.localizedDescription)
                return 2
            }
            _ = report(outcomes)
            Format.printError("Items were restored, but the history couldn't be updated: \(underlying.localizedDescription)")
            return 2
        } catch RunJournalError.notRestorable {
            Format.printError(notRestorableMessage)
            return 1
        } catch {
            Format.printError("Restore failed: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: empty-trash

    static func emptyTrash(_ args: [String]) -> Int32 {
        if let bad = args.first(where: { $0 != "--yes" }) {
            Format.printError("Unknown option: \(bad)")
            return 1
        }
        let inspector = TrashInspector(
            environment: env, journal: journal, logger: RunLogger(directory: env.logsDirectory), sizer: DirectorySizer(),
            includeExternalVolumes: options.includeExternalTrash)
        let contents = inspector.contents()
        let needsAccess = contents.issues.contains { if case .missingFullDiskAccess = $0 { true } else { false } }
        Format.printIssues(contents.issues)

        guard !contents.items.isEmpty else {
            if contents.issues.isEmpty {
                print("The Trash is empty.")
                return 0
            }
            print("Nothing to empty that Dustling can see.")
            if needsAccess { print(Format.fullDiskAccessHint) }
            return 1
        }
        if !contents.issues.isEmpty {
            print("Some Trash locations or items couldn't be read, so they may not be emptied."
                + (needsAccess ? " " + Format.fullDiskAccessHint : ""))
        }

        // Show what will be deleted, largest first, before asking.
        let size = (contents.issues.isEmpty ? "" : "at least ") + Format.bytes(contents.size.bytes)
        print("The Trash holds \(Format.plural(contents.items.count, "item")) (\(size)):")
        let sorted = contents.items.sorted {
            $0.size.bytes != $1.size.bytes ? $0.size.bytes > $1.size.bytes : $0.url.path < $1.url.path
        }
        let limit = 50
        for item in sorted.prefix(limit) {
            print("  \(Format.bytes(item.size.bytes))  \(trashItemName(item.url))")
        }
        if sorted.count > limit {
            let rest = sorted.dropFirst(limit)
            let restBytes = rest.reduce(UInt64(0)) { $0 + $1.size.bytes }
            print("  \u{2026}and \(rest.count) more (\(Format.bytes(restBytes)))")
        }

        let amount = contents.size.bytes > 0 ? " (\(size))" : ""
        guard Format.confirm(
            "Permanently delete \(Format.plural(contents.items.count, "item"))\(amount) from the Trash? "
                + "This can't be undone. [y/N]",
            assumeYes: args.contains("--yes"))
        else {
            print("Cancelled.")
            return 0
        }
        let record = inspector.emptyTrash()
        Format.printEntries(record)
        return Format.printTotals(record)
    }

    /// The item's name for items in ~/.Trash, its full path for a volume's Trash.
    private static func trashItemName(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let home = env.userTrash.resolvingSymlinksInPath().standardizedFileURL.path
        return parent == home ? url.lastPathComponent : Format.path(url)
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
