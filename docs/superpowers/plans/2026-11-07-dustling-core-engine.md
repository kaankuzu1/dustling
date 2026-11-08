# Dustling Core Engine Implementation Plan (Plan 1 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `DustlingCore`, the UI-free engine that does junk scanning, uninstall leftover detection, startup item listing, Trash-first cleanup with a durable restore journal, logging, Empty Trash and health checks. Also build `dustling-cli`, a small command-line front end so Kaan can free disk space and dogfood the engine before the UI exists.

**Architecture:** A Swift package with a library target (`DustlingCore`) and an executable target (`dustling-cli`). Every filesystem root comes from an injected `SystemEnvironment`, every external command goes through `CommandRunning`, and Trash moves go through `TrashBackend`. That lets tests run against a temporary sandbox and never touch the real home folder or Trash. Root-owned items are not handled here: they come back as `.needsAdmin`, and Plan 2 adds the privileged helper.

**Tech Stack:** Swift 6.2 (Xcode 26.3), Swift Package Manager, Swift Testing (`import Testing`), Foundation, AppKit (only `NSRunningApplication`/`NSWorkspace`), Security (`SecStaticCode`) for Team IDs.

**Spec:** `docs/superpowers/specs/2026-11-07-dustling-design.md` (approved by Kaan 2026-11-07)

**Plan series** (the spec covers four independent subsystems, so each gets its own plan):
1. **This plan:** core engine + CLI.
2. Privileged helper (`SMAppService` daemon, XPC, Team ID caller check, root-owned trashing with chown, health/repair). Written after this plan lands.
3. SwiftUI app. Written after Kaan picks the theme and the per-screen variants; blocked on the design threads.
4. Release (Developer ID, notarization, `.dmg`, Homebrew cask, GitHub Releases). Blocked on the paid Apple Developer account.

## Global Constraints

- Minimum OS: macOS 14 (`platforms: [.macOS(.v14)]`). English only. No network access anywhere in the engine. No telemetry.
- Cleaning and uninstalling only **move to Trash**. The single permanent delete is `TrashInspector.emptyTrash()`, and callers must confirm before calling it.
- Result states, verbatim: `moved to Trash`, `skipped: <reason>`, `failed: <reason>`, `needs admin`, `deleted` (the last only from Empty Trash).
- Never fail silently: every attempted item yields an outcome, every run is journaled **and** logged, and totals are computed from actual outcomes, never from the plan.
- Never touch: `/System`, `/bin`, `/sbin`, `/usr`, `/private/var/db`, `/Library/Apple`; in the user's home: `Documents`, `Desktop`, `Pictures`, `Music`, `Movies`, `Library/Mobile Documents`, `Library/Keychains`, `Library/Mail`; and any other user's home. Apps in `/System/Applications` are never listed.
- Uninstall leftovers that may contain user data stay unchecked by default (`mayContainUserData == true` implies `preselected == false`).
- Logs: `~/Library/Logs/Dustling/dustling-YYYY-MM-DD.log`. Journal: `~/Library/Application Support/Dustling/History/<run-id>.json`.
- Full Disk Access settings deep link, verbatim: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- License MIT. The repo is public on GitHub (pushing waits for Kaan to create the repo).

## Review Focus

1. **Steam wrapper apps with no bundle ID** (`~/Applications/Portal.app`, whose `Contents/MacOS/run.sh` runs `open steam://run/400`) must be discovered and uninstallable. Test in Task 9: `discoversSteamWrapperWithoutBundleID`.
2. **Folders unreadable without Full Disk Access** must be reported as "couldn't scan", never as 0 bytes. Test in Task 4: `unreadableRootIsReportedNotZero`.
3. **A symlink inside an allowed root that points into a protected folder** (for example `~/Library/Caches/evil -> ~/Documents`) must be trashed as a link at most, never followed, and never counted toward size. Tests in Task 2 (`symlinkIntoProtectedFolderIsJudgedByLinkLocation`) and Task 3 (`doesNotFollowSymlinks`).
4. **Restore when the original path is occupied again** (the app was reinstalled) must not overwrite. It reports a conflict. Test in Task 6: `restoreDoesNotOverwriteReoccupiedPath`.
5. **Trash name collisions** (two folders named `Caches` both trashed) must be journaled with their real Trash paths so restore puts each one back correctly. Test in Task 6: `journalRecordsActualTrashPathsOnCollision`.

---

### Task 1: Package scaffold, environment, test sandbox

**Files:**
- Create: `Package.swift`, `.gitignore`, `LICENSE` (MIT, "Copyright (c) 2026 Dustling contributors"), `README.md` (name, one-line description, "work in progress", build/test commands)
- Create: `Sources/DustlingCore/Environment/SystemEnvironment.swift`
- Create: `Sources/dustling-cli/main.swift` (prints usage only, for now)
- Create: `Tests/DustlingCoreTests/Support/TestSandbox.swift`
- Test: `Tests/DustlingCoreTests/SystemEnvironmentTests.swift`

**Interfaces:**
- Produces:
  - `public struct SystemEnvironment: Sendable { public var home: URL; public var applicationDirectories: [URL]; public var systemLibrary: URL; public var volumesDirectory: URL; public var userID: uid_t; public static var current: SystemEnvironment }`
  - computed: `userLibrary` (`home/Library`), `userTrash` (`home/.Trash`), `logsDirectory` (`home/Library/Logs/Dustling`), `historyDirectory` (`home/Library/Application Support/Dustling/History`)
  - `.current`: `home` = `FileManager.default.homeDirectoryForCurrentUser`, `applicationDirectories` = `["/Applications", home/Applications]`, `systemLibrary` = `/Library`, `volumesDirectory` = `/Volumes`, `userID` = `getuid()`
  - Test support: `final class TestSandbox { let root: URL; let environment: SystemEnvironment; init() throws; func file(_ relativePath: String, bytes: Int = 1) throws -> URL; func directory(_ relativePath: String) throws -> URL; func app(_ relativePath: String, bundleID: String?, executable: String = "App", script: String? = nil) throws -> URL; deinit /* removes root */ }`. Its environment maps `home`, `systemLibrary`, `volumesDirectory` and `/Applications` to sub-folders of a fresh temp dir.

- [ ] **Step 1:** `git init` in the project folder (`docs/` already exists). Write `Package.swift`: `swift-tools-version: 6.0`, platforms `.macOS(.v14)`, library `DustlingCore`, executable `dustling-cli` depending on it, and test target `DustlingCoreTests`.
- [ ] **Step 2: Write the failing test** `environmentPathsDeriveFromHome`: for `SystemEnvironment(home: URL(filePath: "/tmp/h"), …)`, `#expect(env.userTrash.path == "/tmp/h/.Trash")`, `#expect(env.logsDirectory.path == "/tmp/h/Library/Logs/Dustling")`, `#expect(env.historyDirectory.path == "/tmp/h/Library/Application Support/Dustling/History")`. Also `sandboxIsIsolated`: `TestSandbox().environment.home.path.hasPrefix(FileManager.default.temporaryDirectory.path)`.
- [ ] **Step 3:** Run `swift test --filter SystemEnvironmentTests`. Expected: FAIL (types not defined).
- [ ] **Step 4:** Implement `SystemEnvironment` and `TestSandbox`.
- [ ] **Step 5:** Run `swift test --filter SystemEnvironmentTests` and `swift build`. Expected: PASS, build succeeds.
- [ ] **Step 6: Commit** `chore: scaffold DustlingCore package, environment and test sandbox`

---

### Task 2: Protected paths

**Files:**
- Create: `Sources/DustlingCore/Safety/ProtectedPaths.swift`
- Test: `Tests/DustlingCoreTests/ProtectedPathsTests.swift`

**Interfaces:**
- Consumes: `SystemEnvironment`
- Produces: `public struct ProtectedPaths: Sendable { public init(environment: SystemEnvironment); public func verdict(for url: URL, allowedRoots: [URL]) -> PathVerdict }` and `public enum PathVerdict: Equatable, Sendable { case allowed; case denied(reason: String) }`

Rules, in order:
1. Standardize the path **without resolving the item's own final symlink**, but do resolve its parent directory.
2. Denied if the path is equal to or inside a hard-deny location (Global Constraints list, with home-relative entries resolved against `environment.home`).
3. Denied if it's inside `/Users/<someone else>`.
4. Denied unless it's **strictly inside** (not equal to) one of `allowedRoots`.

Reason strings: `"protected location"`, `"another user's files"`, `"outside the cleanup area"`.

- [ ] **Step 1: Write the failing tests:**
  - `allowsChildOfAllowedRoot`: `home/Library/Caches/com.x` with root `home/Library/Caches` → `.allowed`
  - `deniesTheRootItself`: root itself → `.denied(reason: "outside the cleanup area")`
  - `deniesPersonalFoldersEvenInsideRoot`: `home/Documents/a` with root `home` → `.denied(reason: "protected location")`
  - `deniesSystem`: `/System/Library/x` with root `/` → `.denied(reason: "protected location")`
  - `deniesOtherUsersHome`: `/Users/someoneelse/Library/Caches/x` with root `/Users` → `.denied(reason: "another user's files")`
  - `symlinkIntoProtectedFolderIsJudgedByLinkLocation`: create `home/Library/Caches/evil` → symlink to `home/Documents`; the verdict for the link is `.allowed` (trashing it removes only the link), and the verdict for `home/Library/Caches/evil/secret.txt` (the parent resolves into Documents) is `.denied(reason: "protected location")`
  - `dotDotEscapeIsDenied`: `home/Library/Caches/../../Documents/x` with root `home/Library/Caches` → `.denied`
- [ ] **Step 2:** Run `swift test --filter ProtectedPathsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `ProtectedPaths.verdict(for:allowedRoots:)`.
- [ ] **Step 4:** Run `swift test --filter ProtectedPathsTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): protected path verdicts`

---

### Task 3: Directory sizer

**Files:**
- Create: `Sources/DustlingCore/Scanning/DirectorySizer.swift`
- Test: `Tests/DustlingCoreTests/DirectorySizerTests.swift`

**Interfaces:**
- Produces: `public struct SizeResult: Equatable, Sendable { public var bytes: UInt64; public var fileCount: Int; public var unreadable: [URL] }` and `public struct DirectorySizer: Sendable { public init(); public func measure(_ url: URL) -> SizeResult }`

Use `FileManager.enumerator(at:includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey, .isRegularFileKey], options: [], errorHandler:)`. The error handler appends to `unreadable` and returns `true` (keep going). Symlinks count as 0 and are never followed. A single file returns its own allocated size.

- [ ] **Step 1: Write the failing tests:** `sumsAllocatedSizes` (two 10 000-byte files → `bytes >= 20_000`, `fileCount == 2`), `doesNotFollowSymlinks` (a link to a 1 MB file outside the measured dir adds < 4096 bytes), `reportsUnreadableSubfolder` (subfolder chmod `000` → `unreadable` contains it; restore permissions in `defer`), `measuresSingleFile`.
- [ ] **Step 2:** Run `swift test --filter DirectorySizerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `DirectorySizer.measure(_:)`.
- [ ] **Step 4:** Run `swift test --filter DirectorySizerTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): allocated-size directory measurement`

---

### Task 4: Junk catalog and scanner

**Files:**
- Create: `Sources/DustlingCore/Scanning/JunkCategory.swift`, `Sources/DustlingCore/Scanning/JunkCatalog.swift`, `Sources/DustlingCore/Scanning/JunkScanner.swift`
- Test: `Tests/DustlingCoreTests/JunkScannerTests.swift`

**Interfaces:**
- Consumes: `SystemEnvironment`, `DirectorySizer`
- Produces:
  - `public enum JunkCategoryID: String, CaseIterable, Codable, Sendable { case browserCaches, xcodeJunk, packageManagerCaches, userCaches, userLogs, systemCachesAndLogs, trash, oldInstallers, iosBackups, xcodeArchives, largeOldDownloads, mailDownloads }`
  - `public enum Selection: Sendable { case preselected, review, emptyTrashOnly }`
  - `public struct JunkCategory: Sendable { id; title: String; selection: Selection; requiresAdmin: Bool; roots: [URL]; itemFilter: @Sendable (URL) -> Bool }`
  - `public enum JunkCatalog { public static func standard(_ env: SystemEnvironment, now: Date = .now) -> [JunkCategory] }`. Returned in the enum order above; **an item belongs to the first category that claims it** (browser and Xcode caches are not double-counted in `userCaches`).
  - `public struct JunkItem: Sendable, Identifiable { url; bytes: UInt64; category: JunkCategoryID; inUseByBundleID: String? }`
  - `public struct CategoryScan: Sendable { category: JunkCategory; items: [JunkItem]; bytes: UInt64; issues: [ScanIssue] }` and `public enum ScanIssue: Equatable, Sendable { case unreadable(URL), missingFullDiskAccess(URL) }`
  - `public struct JunkScanner: Sendable { public init(environment:, runningBundleIDs: @Sendable () -> Set<String>); public func scan(_ categories: [JunkCategory], onCategory: @Sendable (CategoryScan) -> Void) async throws -> [CategoryScan] }`. Checks `Task.checkCancellation()` between items. The callback fires as each category finishes (it drives the skeleton rows and the live counter).

Category roots. The unit of deletion is each **direct child** of a root:

| id | roots (H = home, L = systemLibrary) | selection | admin |
|---|---|---|---|
| browserCaches | `H/Library/Caches/` children named `com.apple.Safari`, `Google`, `Firefox`, `BraveSoftware`, `Microsoft Edge`, `company.thebrowser.Browser` | preselected | no |
| xcodeJunk | `H/Library/Developer/Xcode/DerivedData`, `H/Library/Developer/CoreSimulator/Caches` | preselected | no |
| packageManagerCaches | `H/Library/Caches/` children `Homebrew`, `pip`, `CocoaPods`, `Yarn`; `H/.npm/_cacache` | preselected | no |
| userCaches | `H/Library/Caches`, `H/Library/Containers/*/Data/Library/Caches` | preselected | no |
| userLogs | `H/Library/Logs` (excluding `Dustling`) | preselected | no |
| systemCachesAndLogs | `L/Caches`, `L/Logs` | preselected | **yes** |
| trash | `H/.Trash`, `<volumes>/*/.Trashes/<uid>` | emptyTrashOnly | no |
| oldInstallers | `H/Downloads` files ending `.dmg` / `.pkg` | review | no |
| iosBackups | `H/Library/Application Support/MobileSync/Backup` | review | no |
| xcodeArchives | `H/Library/Developer/Xcode/Archives` | review | no |
| largeOldDownloads | `H/Downloads` items ≥ 500 MB **or** last accessed > 90 days ago | review | no |
| mailDownloads | `H/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | review | no |

If a root exists but can't be listed (EPERM), the category gets `.missingFullDiskAccess(root)` and **no** zero-byte success. An item whose name equals a running app's bundle ID gets `inUseByBundleID`.

- [ ] **Step 1: Write the failing tests:**
  - `browserCacheIsNotDoubleCounted`: `H/Library/Caches/Google/x` (1 KB) and `H/Library/Caches/com.foo/y` (1 KB) → the browserCaches items are `[Google]`, the userCaches items are `[com.foo]`
  - `selectionsMatchSpec`: `standard(env)` maps `trash → .emptyTrashOnly`, `oldInstallers → .review`, `userCaches → .preselected`, and `systemCachesAndLogs.requiresAdmin == true`
  - `unreadableRootIsReportedNotZero`: chmod `000` on `H/Library/Caches` → the userCaches scan has `issues == [.missingFullDiskAccess(root)]`
  - `largeOldDownloadsUsesThresholds`: a 600 MB sparse file (`FileHandle.truncate`) and a small file with access date 100 days ago are both included; a small, recent file is not
  - `marksCachesOfRunningApps`: `runningBundleIDs = ["com.foo"]` → the item `com.foo` has `inUseByBundleID == "com.foo"`
  - `scanIsCancellable`: cancel the task before the first category → throws `CancellationError`
- [ ] **Step 2:** Run `swift test --filter JunkScannerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the catalog and scanner.
- [ ] **Step 4:** Run `swift test --filter JunkScannerTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): junk catalog and cancellable scanner`

---

### Task 5: Trash mover and outcomes

**Files:**
- Create: `Sources/DustlingCore/Cleanup/DeletionOutcome.swift`, `Sources/DustlingCore/Cleanup/TrashBackend.swift`, `Sources/DustlingCore/Cleanup/TrashMover.swift`
- Create (test support): `Tests/DustlingCoreTests/Support/DirectoryTrashBackend.swift`
- Test: `Tests/DustlingCoreTests/TrashMoverTests.swift`

**Interfaces:**
- Consumes: `ProtectedPaths`
- Produces:
  - `public enum DeletionOutcome: Codable, Equatable, Sendable { case movedToTrash(trashedPath: String); case skipped(reason: String); case failed(reason: String); case needsAdmin; case deleted }` with `public var label: String` returning exactly `"moved to Trash"`, `"skipped: <reason>"`, `"failed: <reason>"`, `"needs admin"`, `"deleted"`
  - `public protocol TrashBackend: Sendable { func trash(_ url: URL) throws -> URL }`. `SystemTrashBackend` uses `FileManager.trashItem(at:resultingItemURL:)`. The test `DirectoryTrashBackend(directory:)` mimics Finder collision naming (`Caches`, `Caches 2`, `Caches 3`).
  - `public struct TrashMover: Sendable { public init(backend: TrashBackend, protectedPaths: ProtectedPaths); public func moveToTrash(_ url: URL, allowedRoots: [URL]) -> DeletionOutcome }`

Order of checks: protected verdict (`.skipped(reason:)`) → item missing (`.skipped(reason: "already gone")`) → parent directory not writable by the current user (`access(parent, W_OK) != 0`) → `.needsAdmin` → backend throws → `.failed(reason: error.localizedDescription)`.

- [ ] **Step 1: Write the failing tests:** `movesAllowedItem` (returns `.movedToTrash` and the source no longer exists), `protectedItemIsSkippedWithReason`, `missingItemIsSkipped`, `unwritableParentNeedsAdmin` (parent chmod `555`), `backendErrorBecomesFailedWithReason` (a throwing backend → `.failed(reason:)` containing the error text), `labelsAreVerbatim` (all five labels).
- [ ] **Step 2:** Run `swift test --filter TrashMoverTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter TrashMoverTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): trash mover with explicit outcomes`

---

### Task 6: Run journal and restore

**Files:**
- Create: `Sources/DustlingCore/History/RunRecord.swift`, `Sources/DustlingCore/History/RunJournal.swift`
- Test: `Tests/DustlingCoreTests/RunJournalTests.swift`

**Interfaces:**
- Consumes: `DeletionOutcome`, `SystemEnvironment.historyDirectory`
- Produces:
  - `public enum RunKind: Codable, Equatable, Sendable { case junkClean, uninstall(appName: String), emptyTrash, startupChange }`
  - `public struct JournalEntry: Codable, Equatable, Sendable { public var originalPath: String; public var bytes: UInt64; public var outcome: DeletionOutcome; public var restored: Bool }`
  - `public struct RunRecord: Codable, Identifiable, Sendable { id: UUID; startedAt: Date; kind: RunKind; entries: [JournalEntry]; restorable: Bool }` with computed `bytesMovedToTrash`, `failedCount`, `needsAdminCount`, `skippedCount`
  - `public enum RestoreOutcome: Equatable, Sendable { case restored(String), conflict(String), missingFromTrash(String) }`
  - `public struct RunJournal: Sendable { public init(directory: URL); public func save(_ run: RunRecord) throws; public func all() throws -> [RunRecord] /* newest first */; public func restore(runID: UUID, paths: Set<String>? = nil) throws -> [RestoreOutcome]; public func refreshRestorability() throws }`

Restore moves each `movedToTrash` entry (filtered by `paths` if given) from `trashedPath` back to `originalPath`, creating missing parent folders. If `originalPath` exists → `.conflict` (never overwrite). If `trashedPath` is gone → `.missingFromTrash`. Restored entries get `restored = true` and are saved. `refreshRestorability()` sets `restorable = false` on runs where no unrestored trashed path still exists.

- [ ] **Step 1: Write the failing tests:**
  - `saveAndLoadRoundTrip` (two runs; `all()` is newest-first and equal to what was saved)
  - `restoreMovesBackAndMarksRestored`
  - `restoreDoesNotOverwriteReoccupiedPath`: recreate the original path before restoring → `[.conflict(original)]`, the trashed copy is still in the trash, the new file is untouched
  - `journalRecordsActualTrashPathsOnCollision`: trash `a/Caches` and `b/Caches` through `DirectoryTrashBackend` → the journaled trashed paths end `Caches` and `Caches 2`, and restoring both returns each to its own original folder with its own contents
  - `missingTrashedItemIsReported`
  - `refreshMarksEmptiedRunsNotRestorable`
- [ ] **Step 2:** Run `swift test --filter RunJournalTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. JSON with `.iso8601` dates, one file per run, written atomically.
- [ ] **Step 4:** Run `swift test --filter RunJournalTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): durable run journal with restore`

---

### Task 7: Run logger and cleanup runner

**Files:**
- Create: `Sources/DustlingCore/History/RunLogger.swift`, `Sources/DustlingCore/Cleanup/CleanupRunner.swift`
- Test: `Tests/DustlingCoreTests/CleanupRunnerTests.swift`

**Interfaces:**
- Consumes: `TrashMover`, `RunJournal`, `DirectorySizer`, `SystemEnvironment.logsDirectory`
- Produces:
  - `public struct RunLogger: Sendable { public init(directory: URL); public func write(_ run: RunRecord) throws }`. It appends to `dustling-YYYY-MM-DD.log` (local date): a header line `<ISO8601> run=<uuid> kind=<kind>`, then one line per entry: `  <outcome label>  <bytes, ByteCountFormatter .file>  <originalPath>[ -> <trashedPath>]`, then a totals line.
  - `public struct CleanupRunner: Sendable { public init(mover: TrashMover, journal: RunJournal, logger: RunLogger, sizer: DirectorySizer); public func run(_ urls: [URL], kind: RunKind, allowedRoots: [URL], onItem: @Sendable (URL, DeletionOutcome) -> Void) async -> RunRecord }`

The runner measures each item **before** moving it, records every outcome, then saves the journal and writes the log. If saving or logging throws, the returned record is still complete and the error is appended as an extra entry with `originalPath` `"<history>"` or `"<log>"`, `.failed(reason:)` and 0 bytes. Nothing is swallowed.

- [ ] **Step 1: Write the failing tests:** `everyItemGetsAnOutcomeAndOnItemFires` (3 items, one protected → `onItem` called 3 times, entries count 3), `totalsComeFromActualOutcomes` (one move fails via a throwing backend → `bytesMovedToTrash` excludes it), `runIsJournaledAndLogged` (the journal has it; the log file contains `run=<id>` and `moved to Trash`), `logFailureIsRecordedNotSwallowed` (unwritable log dir → the record has a `<log>` failed entry).
- [ ] **Step 2:** Run `swift test --filter CleanupRunnerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter CleanupRunnerTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): cleanup runner with journal and human-readable log`

---

### Task 8: Trash inspector and Empty Trash

**Files:**
- Create: `Sources/DustlingCore/Cleanup/TrashInspector.swift`
- Test: `Tests/DustlingCoreTests/TrashInspectorTests.swift`

**Interfaces:**
- Consumes: `SystemEnvironment`, `DirectorySizer`, `RunJournal`, `RunLogger`
- Produces: `public struct TrashInspector: Sendable { public init(environment:, journal:, logger:, sizer:); public func trashLocations() -> [URL] /* H/.Trash + <volumes>/*/.Trashes/<uid> that exist */; public func size() -> SizeResult; public func emptyTrash() -> RunRecord }`

`emptyTrash()` permanently removes each direct child of each trash location with `FileManager.removeItem`. Each one gets `.deleted` or `.failed(reason:)`; unreadable locations become `.failed(reason: "no access, grant Full Disk Access")`. Then it saves a `.emptyTrash` run, logs it, and calls `journal.refreshRestorability()`.

- [ ] **Step 1: Write the failing tests:** `includesExternalVolumeTrash` (`<volumes>/Ext/.Trashes/<uid>/f` counted), `emptyTrashDeletesAndReports` (2 items → 2 `.deleted`, the folder is empty, run kind `.emptyTrash`), `emptyTrashMakesEarlierRunsNotRestorable`, `undeletableItemIsReported` (an item inside a `555` subfolder → `.failed`).
- [ ] **Step 2:** Run `swift test --filter TrashInspectorTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter TrashInspectorTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): trash sizing and confirmed Empty Trash`

---

### Task 9: App discovery

**Files:**
- Create: `Sources/DustlingCore/Uninstaller/InstalledApp.swift`, `Sources/DustlingCore/Uninstaller/AppScout.swift`
- Test: `Tests/DustlingCoreTests/AppScoutTests.swift`

**Interfaces:**
- Consumes: `SystemEnvironment`, `DirectorySizer`
- Produces:
  - `public struct InstalledApp: Identifiable, Hashable, Sendable { url; displayName: String; bundleID: String?; teamID: String?; executableName: String?; steamAppID: String?; bytes: UInt64; lastUsed: Date? }`
  - `public struct AppScout: Sendable { public init(environment:, sizer:); public func discover() -> [InstalledApp] /* sorted by displayName, case-insensitive */ }`

Search `environment.applicationDirectories` to depth 3, without descending into any `.app` bundle, and never list `/System/Applications`. `displayName` priority: `CFBundleDisplayName` → `CFBundleName` → file name without `.app`. `teamID` comes from `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation` (`kSecCodeInfoTeamIdentifier`), or nil. `steamAppID` is the digits after `steam://run/` in the bundle executable when that file is a text script. `lastUsed` is `URLResourceValues.contentAccessDate`.

- [ ] **Step 1: Write the failing tests:**
  - `discoversNestedApps` (`Applications/TI Connect/TI Data Editor.app` is found)
  - `doesNotDescendIntoBundles` (an `.app` inside `X.app/Contents/Helpers` is not listed)
  - `discoversSteamWrapperWithoutBundleID`: `TestSandbox.app("Applications/Portal.app", bundleID: nil, executable: "run.sh", script: "#!/bin/bash\n# autogenerated file - do not edit\nopen steam://run/400\n")` → listed with `displayName == "Portal"`, `bundleID == nil`, `steamAppID == "400"`
  - `namePriority` (DisplayName beats BundleName beats file name)
- [ ] **Step 2:** Run `swift test --filter AppScoutTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter AppScoutTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): app discovery incl. apps without bundle IDs`

---

### Task 10: Leftover finder

**Files:**
- Create: `Sources/DustlingCore/Support/CommandRunning.swift`, `Sources/DustlingCore/Uninstaller/Leftover.swift`, `Sources/DustlingCore/Uninstaller/LeftoverFinder.swift`
- Create (test support): `Tests/DustlingCoreTests/Support/FakeCommandRunner.swift`
- Test: `Tests/DustlingCoreTests/LeftoverFinderTests.swift`

**Interfaces:**
- Consumes: `InstalledApp`, `SystemEnvironment`, `DirectorySizer`
- Produces:
  - `public struct CommandResult: Sendable { status: Int32; stdout: String; stderr: String }`, `public protocol CommandRunning: Sendable { func run(_ executable: String, _ arguments: [String]) throws -> CommandResult }`, `public struct ProcessCommandRunner: CommandRunning` (uses `Process`)
  - `public enum LeftoverKind: String, Codable, Sendable { case applicationSupport, caches, preferences, container, groupContainer, savedState, httpStorage, webKit, logs, cookies, launchAgent, launchDaemon, privilegedHelper, packageReceipt, steamGameData }`
  - `public enum MatchStrength: Sendable { case exact, nameBased }`
  - `public struct Leftover: Identifiable, Hashable, Sendable { url: URL; kind: LeftoverKind; match: MatchStrength; mayContainUserData: Bool; requiresAdmin: Bool; bytes: UInt64; var preselected: Bool { match == .exact && !mayContainUserData } }`
  - `public struct LeftoverFinder: Sendable { public init(environment:, sizer:, commands: CommandRunning); public func leftovers(for app: InstalledApp) -> [Leftover] }`

Rules (H = home, L = systemLibrary, B = bundle ID, T = team ID, N = display name):
- Exact, `mayContainUserData = false`: `H/Library/Caches/B`, `H/Library/Preferences/B.plist`, `H/Library/Preferences/ByHost/B.*.plist`, `H/Library/Saved Application State/B.savedState`, `H/Library/HTTPStorages/B` (and `B.binarycookies`), `H/Library/WebKit/B`, `H/Library/Logs/B`, `H/Library/Cookies/B.binarycookies`.
- Exact, `mayContainUserData = true`: `H/Library/Application Support/B`, `H/Library/Containers/B`, `H/Library/Group Containers/T.*` (only when `teamID` is non-nil).
- Name-based, `mayContainUserData = true`: `H/Library/Application Support/N`, `H/Library/Caches/N` (this one is `mayContainUserData = false`), `H/Library/Logs/N` (`false`).
- Launch agents and daemons: each plist in `H/Library/LaunchAgents`, `L/LaunchAgents`, `L/LaunchDaemons` whose `Program` or `ProgramArguments[0]` lies inside `app.url`, or whose `Label` starts with `B` → exact, `false`; `requiresAdmin` for the `L/` ones. Helpers in `L/PrivilegedHelperTools` named `B*` → exact, `requiresAdmin`.
- Package receipts: `pkgutil --file-info <app path>` → each `pkgid:` line → a `packageReceipt` with url `/private/var/db/receipts/<pkgid>.plist` (never attempted here, recorded as needs admin), `requiresAdmin = true` (removal happens in Plan 2).
- Steam: when `steamAppID` is set, read `H/Library/Application Support/Steam/steamapps/appmanifest_<id>.acf`, take `"installdir"`, and emit `steamapps/common/<installdir>` plus the manifest itself as `steamGameData`, exact, `mayContainUserData = true` (review, unchecked).
- Only existing paths are returned, de-duplicated by URL, each with its measured `bytes`.

- [ ] **Step 1: Write the failing tests:**
  - `exactCachesArePreselected` (`Caches/com.foo` → `.caches`, `.exact`, `preselected == true`)
  - `applicationSupportIsUserDataAndUnchecked` (`Application Support/com.foo` → `mayContainUserData == true`, `preselected == false`)
  - `groupContainerMatchesTeamID`
  - `launchAgentMatchedByProgramPath` (plist `ProgramArguments[0]` = `<app>/Contents/MacOS/helper` → `.launchAgent`, exact)
  - `steamGameDataIsReviewItem`: an appmanifest with `"installdir"		"Portal"` → leftovers include `steamapps/common/Portal` (`.steamGameData`, `preselected == false`)
  - `packageReceiptsNeedAdmin`: `FakeCommandRunner` returns `"volume: /\npath: …\n\npkgid: com.foo.pkg\n"` → a `.packageReceipt` with `requiresAdmin == true`
  - `nonexistentPathsAreOmitted`
- [ ] **Step 2:** Run `swift test --filter LeftoverFinderTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter LeftoverFinderTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): leftover detection with user-data classification`

---

### Task 11: Uninstall execution

**Files:**
- Create: `Sources/DustlingCore/Uninstaller/Uninstaller.swift`
- Test: `Tests/DustlingCoreTests/UninstallerTests.swift`

**Interfaces:**
- Consumes: `InstalledApp`, `Leftover`, `CleanupRunner`, `CommandRunning`, `SystemEnvironment`
- Produces:
  - `public protocol RunningAppsProviding: Sendable { func isRunning(_ app: InstalledApp) -> Bool }`, with `WorkspaceRunningApps` matching `NSRunningApplication.bundleURL == app.url`
  - `public enum UninstallError: Error, Equatable { case appIsRunning(String) }`
  - `public struct Uninstaller: Sendable { public init(runner: CleanupRunner, commands: CommandRunning, running: RunningAppsProviding, environment: SystemEnvironment); public func uninstall(_ app: InstalledApp, leftovers: [Leftover], onItem: @Sendable (URL, DeletionOutcome) -> Void) async throws -> RunRecord }`

Steps:
1. If the app is running, throw `.appIsRunning(displayName)`. The UI/CLI offers to quit it.
2. For each selected user launch agent: `launchctl bootout gui/<uid> <plist path>` (a non-zero status is logged as a `.failed` entry with `originalPath` = the plist and reason `"could not unload: <stderr>"`, then trashing continues).
3. Leftovers with `requiresAdmin` are recorded as `.needsAdmin` without being attempted.
4. Run `CleanupRunner.run([app.url] + other leftover urls, kind: .uninstall(appName:), allowedRoots: environment.applicationDirectories + leftover parent folders)`.

The app bundle always comes first in the entries.

- [ ] **Step 1: Write the failing tests:** `runningAppThrows`, `bootsOutUserLaunchAgentBeforeTrashing` (the `FakeCommandRunner` sees `["bootout", "gui/<uid>", "<plist>"]`, and that call precedes the move in `onItem` order), `adminLeftoversAreNeedsAdmin`, `appBundleIsFirstEntryAndMovedToTrash`.
- [ ] **Step 2:** Run `swift test --filter UninstallerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter UninstallerTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): uninstall execution`

---

### Task 12: Startup items (spike, then scanner and user-level toggle)

**Files:**
- Create: `docs/superpowers/research/login-items-spike.md`
- Create: `Sources/DustlingCore/Startup/StartupItem.swift`, `Sources/DustlingCore/Startup/StartupItemScanner.swift`
- Test: `Tests/DustlingCoreTests/StartupItemScannerTests.swift`

**Interfaces:**
- Consumes: `SystemEnvironment`, `CommandRunning`, `AppScout` output (for owner matching)
- Produces:
  - `public enum StartupScope: String, Codable, Sendable { case loginItem, userAgent, systemAgent, systemDaemon }`
  - `public struct StartupItem: Identifiable, Hashable, Sendable { label: String; scope: StartupScope; plistURL: URL?; program: String?; ownerAppName: String?; isEnabled: Bool; managedInSystemSettingsOnly: Bool }`
  - `public struct StartupItemScanner: Sendable { public init(environment:, commands:, apps: [InstalledApp]); public func scan() -> [StartupItem]; public func setEnabled(_ item: StartupItem, _ enabled: Bool) -> DeletionOutcome }`

- [ ] **Step 1: Spike (time-box 1 hour).** On the development Mac (macOS 26), find out what can be read and toggled without root:
  - `launchctl print-disabled gui/$(id -u)`
  - `sfltool dumpbtm` (does it need root?)
  - `SMAppService.statusForLegacyURL`
  - the BTM database location

  Write the findings to the research doc: for each scope, whether it's listable, how enablement is read, whether it's toggleable without admin, and what the System Settings deep link is (`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`). **Decide** `loginItem` support from the findings. If it isn't programmatically listable without root, emit no `loginItem` rows in this plan and mark the gap for Plan 2.
- [ ] **Step 2: Write the failing tests:**
  - `listsUserAndSystemAgents` (plists in sandbox `H/Library/LaunchAgents`, `L/LaunchAgents`, `L/LaunchDaemons` → three items with the right scopes and labels)
  - `readsDisabledStateFromLaunchctl` (fake `print-disabled` output `"com.foo.agent" => disabled` → `isEnabled == false`)
  - `ownerMatchedByProgramPath`
  - `userAgentToggleUsesLaunchctl` (`setEnabled(false)` runs `["disable", "gui/<uid>/<label>"]` then `["bootout", "gui/<uid>/<label>"]` and returns `.skipped(reason: "disabled")`)

    Note: this reuses `DeletionOutcome` as the action result; `.skipped(reason: "disabled"|"enabled")` signals success.
  - `systemItemsNeedAdmin` (`setEnabled` on `.systemDaemon` → `.needsAdmin`)
  - `malformedPlistIsListedWithIssue` (unparsable plist → still listed, `program == nil`, label = file name)
- [ ] **Step 3:** Run `swift test --filter StartupItemScannerTests`. Expected: FAIL.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Run `swift test --filter StartupItemScannerTests`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(core): startup item scanning and user-level toggle` (include the research doc)

---

### Task 13: Health check and storage numbers

**Files:**
- Create: `Sources/DustlingCore/Health/FullDiskAccess.swift`, `Sources/DustlingCore/Health/StorageInfo.swift`, `Sources/DustlingCore/Health/HealthCheck.swift`
- Test: `Tests/DustlingCoreTests/HealthCheckTests.swift`

**Interfaces:**
- Consumes: `SystemEnvironment`, `CommandRunning`
- Produces:
  - `public enum FullDiskAccessStatus: Equatable, Sendable { case granted, denied, unknown }`, `public struct FullDiskAccessProbe: Sendable { public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!; public init(environment:); public func status() -> FullDiskAccessStatus }`. It actually tries to open `H/Library/Application Support/com.apple.TCC/TCC.db` for reading: success → `.granted`, `EPERM`/`EACCES` → `.denied`, missing → `.unknown`.
  - `public struct StorageInfo: Equatable, Sendable { totalBytes: Int64; availableForImportantUsage: Int64; localSnapshotCount: Int }` and `public struct StorageReader: Sendable { public init(commands:); public func read(volume: URL = URL(filePath: "/")) throws -> StorageInfo }`. It uses `volumeTotalCapacityKey` and `volumeAvailableCapacityForImportantUsageKey`, and gets the snapshot count from the lines of `tmutil listlocalsnapshots /` that contain `com.apple.TimeMachine.`.
  - `public struct HealthReport: Sendable { fullDiskAccess: FullDiskAccessStatus; storage: StorageInfo?; problems: [String] }` and `public struct HealthCheck: Sendable { public func run() -> HealthReport }`. `problems` holds plain sentences, for example `"Full Disk Access is off, so some folders can't be scanned."` and `"Storage numbers unavailable: <error>"`.
- [ ] **Step 1: Write the failing tests:** `fdaDeniedWhenTCCUnreadable` (sandbox TCC.db chmod `000` → `.denied`), `fdaGrantedWhenReadable`, `fdaUnknownWhenMissing`, `settingsURLIsVerbatim`, `snapshotCountParsesTmutil` (fake output with 2 snapshot lines → 2), `problemsArePlainSentences` (denied → `problems` contains the exact FDA sentence above).
- [ ] **Step 2:** Run `swift test --filter HealthCheckTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter HealthCheckTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): health check, FDA probe and storage numbers`

---

### Task 14: `dustling-cli`

**Files:**
- Modify: `Sources/dustling-cli/main.swift`
- Create: `Sources/dustling-cli/Commands.swift`, `Sources/dustling-cli/Format.swift`
- Modify: `README.md` (CLI usage section)

**Interfaces:**
- Consumes: all `DustlingCore` public types above with `SystemEnvironment.current`, `SystemTrashBackend`, `ProcessCommandRunner`, `WorkspaceRunningApps`

Commands (hand-parsed `CommandLine.arguments`, no dependencies):
- `doctor`: the HealthReport. Prints FDA status, available space, snapshot count and problems. Exit code 1 if there are any problems.
- `scan`: categories with size and item count, a `[review]` / `[trash]` tag for non-preselected ones, issues listed under each category.
- `clean [--include <categoryID>…]`: scan, show the preselected categories plus any `--include`d ones with the total, prompt `Move N items (X) to Trash? [y/N]`, run, print each outcome label and the totals line, then print `Space is freed when the Trash is emptied: dustling empty-trash`.
- `apps`: a numbered list with size.
- `uninstall <name|number> [--all]`: the leftover list, with `[x]` for preselected and `[ ]` for unchecked plus the `may contain your data` badge. `--all` includes unchecked items, and prints a warning line for each user-data item. Then confirm, run, print outcomes.
- `startup`: a table of the items. `startup disable|enable <label>`.
- `history`: the runs, with a `restorable` marker. `restore <run-id-prefix> [--path <p>]`.
- `empty-trash`: show the size, prompt `Permanently delete X from the Trash? This can't be undone. [y/N]`, run, print outcomes.

Every non-confirmed prompt exits with `Cancelled.` and code 0. Any `failed`/`needs admin` outcomes make the exit code 2.

- [ ] **Step 1:** Implement the commands.
- [ ] **Step 2: Manual verification on the development Mac** (read-only first):
  - `swift run dustling-cli doctor`: prints an FDA status and available GB. If the terminal lacks FDA it shows the problem sentence.
  - `swift run dustling-cli scan`: categories appear, with non-zero sizes for caches.
  - `swift run dustling-cli apps`: includes any Steam wrapper apps.
  - `swift run dustling-cli uninstall Portal`: shows `steamapps/common/Portal` as `[ ]` with the data badge. Answer `N` → `Cancelled.`
- [ ] **Step 3:** Run `swift test`. Expected: all suites PASS.
- [ ] **Step 4: Commit** `feat(cli): dustling-cli front end for the core engine`

---

## Done when

- `swift test` passes with all suites green, and `swift build -c release` succeeds.
- The Task 14 manual checks are done on the development Mac, and their output is pasted into the PR or summary.
- Kaan can, with `dustling-cli`, see where space went, clean preselected junk to the Trash, empty the Trash, and restore a run from history.
