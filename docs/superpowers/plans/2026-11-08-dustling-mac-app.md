# Dustling Mac App Implementation Plan (Plan 3 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Dustling Mac app: a SwiftUI interface in the approved Mosaic design, on top of the tested `DustlingCore` engine. It covers onboarding with Full Disk Access, Home with the storage mosaic, Junk scan, Uninstaller, Startup items, History and Restore, Settings, and errors and repair.

**Architecture:** There are three layers.
1. **Engine prerequisites (Tasks 1–4).** They close the Plan-3 gaps from the core engine's final review.
2. **`DustlingAppModel`.** A new SwiftPM library target holding the testable, UI-free logic for the screens: mosaic layout, the update goal, formatting, and one `@Observable` model per screen. It is tested with `swift test`.
3. **The app target `Dustling`.** It's generated with XcodeGen from `App/project.yml`, depends on the local package, and contains only SwiftUI views, the theme and resources.

The privileged helper is Plan 2. Here, every helper-dependent control renders an honest "Not available yet" state.

**Tech Stack:**
- Swift 6.2, SwiftUI with the Observation framework (`@Observable`), macOS 14+.
- XcodeGen 2.44 (already installed at `/opt/homebrew/bin/xcodegen`) and Xcode 26.3.
- Swift Testing, plus the existing `DustlingCore`.

**Spec:** `docs/superpowers/specs/2026-11-07-dustling-design.md`. Approved design inputs, which are binding:
- `~/Desktop/mac-cleaner-design/handoff/SCREENS-final.md` (Kaan approved 2026-11-07)
- `~/Desktop/mac-cleaner-design/handoff/DESIGN-mosaic.md`
- `~/Desktop/mac-cleaner-design/handoff/DustlingTheme.swift`
- The exact markup per frame: the `MIX` object in `~/Desktop/mac-cleaner-design/screens.html`
- Live reference: https://claude.ai/artifact/3XDHiKLBdHWafP7vpbzn8t
- Logo kit: project files `design/logo/final/` (the icon colours are final)

## Global Constraints

- macOS 14 minimum. English only. Sentence case, no em dashes, no exclamation marks in UI copy (DESIGN-mosaic §10).
- Cleaning and uninstalling only move to the Trash. Empty Trash is the single permanent delete and always confirms in a sheet with the destructive style. The "Always confirm before Empty Trash" setting is locked on.
- **Never fail silently.** Every item ends as `moved to Trash`, `skipped: <reason>`, `failed: <reason>`, `needs admin` or `deleted`. UI totals come from `RunRecord` outcomes, never from the plan. A place Dustling can't read renders as hatched "locked" cells with a reason, never as 0 bytes.
- No network for cleaning. No telemetry, no update check, no account.
- **Mosaic rules.**
  - One cell = 0.25 GB. 4 rows, columns = ceil(cells/4), square cells, 2 pt gap.
  - Order: free space, then categories largest first, then other files.
  - Files moved to the Trash but not yet emptied render as hatched "in Trash" cells until Empty Trash.
- **Pixel art.**
  - Fonts: Geist 13 for UI, Geist Pixel only for window titles and big figures (never under 13 pt), Geist Mono 11.5 for paths. Changing numbers use tabular figures.
  - Mote and pixel icons are drawn with `Canvas` at integer scales only.
- **Reduce Motion.** No walking, chomping, breathing, nibble stagger or count-up. Values change instantly, spinners become a static "Moving…" label, and nothing waits for an animation.
- Category colours are used only for data (cells, bars, legend), never for chrome or behind text. The Trash uses neutral colours and the SF Symbol `trash`.
- Helper-dependent features (system caches, daemons, receipts) show "Needs the cleanup helper (coming in a later version)". They never offer a button that can't work.
- The app is unsandboxed (Full Disk Access is required), bundle ID `app.dustling.Dustling`. Local builds use automatic signing with Kaan's Personal Team when it's set in `App/Local.xcconfig` (git-ignored), else "Sign to Run Locally".
- Fonts are SIL OFL 1.1; bundle their `OFL.txt` files. The app icon comes from the logo kit as is.

## Review Focus

1. **Full Disk Access granted while onboarding is open.** The status must flip within 2 s without a relaunch. The probe must re-run when the app becomes active, because a rebuild can silently revoke access. Test in Task 6: `fdaPollingFlipsToGrantedWithoutRestart`.
2. **Scan cancelled with Stop mid-category.** The results show what finished, and the partial category is marked "scan stopped", never a smaller total presented as complete. Test in Task 7: `stopMarksPartialCategory`.
3. **Some items skipped or failed during a clean.** The summary headline uses the moved bytes only, and lists skipped and failed counts with reasons. "Put everything back" restores only the moved items. Test in Task 7: `summaryUsesActualOutcomes`.
4. **The Trash is unreadable without Full Disk Access.** The Empty Trash button is disabled with the reason. It never says "0 bytes", and the sheet never asks to delete 0 bytes. Test in Task 7: `emptyTrashDisabledWhenTrashUnreadable`.
5. **Uninstalling a running app.** The confirm button reads "Quit <app> and move to Trash". If quitting fails or times out (10 s), that app is skipped with a reason and the others proceed. Test in Task 8: `runningAppThatWontQuitIsSkippedOthersProceed`.

---

## Part A: engine prerequisites (Plan-3 items from the core review)

### Task 1: Incremental journaling and live progress in CleanupRunner

**Files:**
- Modify: `Sources/DustlingCore/Cleanup/CleanupRunner.swift`, `Sources/DustlingCore/History/RunLogger.swift`
- Test: `Tests/DustlingCoreTests/CleanupRunnerTests.swift`

**Interfaces:**
- Produces:
  - `run(_:kind:allowedRoots:extraEntries:onItemStart: @Sendable (URL) -> Void = { _ in }, onItem:)`. `onItemStart` fires before each move.
  - `startedAt` is captured before the loop.
  - The journal is saved (atomically) after EVERY item, and the log gets one appended line per item, so an interrupted run (Ctrl-C, crash) is recorded up to the last finished item.
  - New `public static func recoverInterrupted(journal:) throws -> [UUID]` returns the ids of runs whose record is marked `inProgress == true` and marks them finished. A new field `inProgress: Bool` (default false when decoding old records) is set true while running.
- [ ] Test `interruptedRunIsJournaledUpToLastItem`: a backend that `fatalError`s can't be used. Instead, a backend that cancels the surrounding `Task` after item 2, plus a runner that checks cancellation between items. The journal on disk has 2 entries and `inProgress == true`, and `recoverInterrupted` returns that id and clears the flag.
- [ ] Test `onItemStartPrecedesOnItem`.
- [ ] Test `startedAtIsBeforeFirstMove`.
- [ ] Implement, `swift test`, commit `feat(core): incremental journaling and item-start callback`.

### Task 2: Journal startup changes

**Files:**
- Create: `Sources/DustlingCore/Startup/StartupChangeRecorder.swift`
- Test: `Tests/DustlingCoreTests/StartupChangeRecorderTests.swift`

**Interfaces:**
- Produces: `public struct StartupChangeRecorder: Sendable { public init(scanner: StartupItemScanner, journal: RunJournal, logger: RunLogger); public func setEnabled(_ item: StartupItem, _ enabled: Bool) -> RunRecord }`.
  - It writes a `.startupChange` run with one entry: originalPath = the plist path or the label, the outcome from `scanner.setEnabled`, and `restorable = false`.
  - It logs the run. Journal and log failures are appended as entries, using the CleanupRunner pattern.
- [ ] Tests:
  - `toggleIsJournaledAndLogged`
  - `failedToggleIsJournaledAsFailed`
  - `loginItemToggleRecordsSystemSettingsFailure`
- [ ] Implement, test, commit `feat(core): journal startup changes`.

### Task 3: Live scan progress and in-category cancellation

**Files:**
- Modify: `Sources/DustlingCore/Scanning/JunkScanner.swift`, `Sources/DustlingCore/Scanning/DirectorySizer.swift`
- Test: `Tests/DustlingCoreTests/JunkScannerTests.swift`

**Interfaces:**
- Produces: `public struct ScanProgress: Sendable { currentPath: URL; bytesFound: UInt64; categoriesDone: Int; categoriesTotal: Int }`.
- `scan(_:onCategory:onProgress: @Sendable (ScanProgress) -> Void = { _ in })` emits progress at most every 100 ms.
- `DirectorySizer.measure(_:isCancelled: () -> Bool = { false })` stops early and returns `SizeResult` with a new `cancelled: Bool`.
- `CategoryScan` gains `stopped: Bool`. A cancelled scan returns the categories finished so far, plus the in-progress one marked `stopped = true`, instead of throwing. `CancellationError` is no longer thrown, and the existing `scanIsCancellable` test is updated to assert the partial result.
- [ ] Tests:
  - `progressIsThrottledAndMonotonic`
  - `stopMarksPartialCategory` (Review Focus 2)
  - `cancelDuringHugeDirectoryStopsQuickly`: 20 000 files, cancel after the first progress tick, returns in under 1 s.
- [ ] Implement, test, commit `feat(core): live scan progress and stop mid-category`.

### Task 4: Scan options and user exclusions

**Files:**
- Create: `Sources/DustlingCore/Scanning/ScanOptions.swift`
- Modify: `JunkCatalog.swift`, `JunkScanner.swift`, `Safety/ProtectedPaths.swift`
- Test: `Tests/DustlingCoreTests/ScanOptionsTests.swift`

**Interfaces:**
- Produces: `public struct ScanOptions: Codable, Equatable, Sendable { var skipChangedWithinDays: Int? = nil; var includeExternalTrash = true; var exclusions: [String] = [] }`.
- `JunkCatalog.standard(_:now:options:)` drops items modified within N days and items inside an exclusion.
- `ProtectedPaths(environment:extraDenied: [URL] = [])` treats exclusions as hard-denied, with reason `"excluded in Settings"`. An exclusion that is itself a protected location is a no-op.
- [ ] Tests:
  - `recentlyChangedItemsAreSkipped`
  - `excludedFolderIsNeverScannedNorMoved` (scanner + TrashMover)
  - `externalTrashToggle`
- [ ] Implement, test, commit `feat(core): scan options and user exclusions`.

## Part B: app model (`DustlingAppModel`, testable)

### Task 5: App model target, formatting, mosaic layout, update goal

**Files:**
- Modify: `Package.swift`. Add the library `DustlingAppModel` (depends on `DustlingCore`) and the test target `DustlingAppModelTests`.
- Create:
  - `Sources/DustlingAppModel/Formatting/Bytes.swift` (move the CLI's locale-independent byte formatter here; the CLI imports it)
  - `Sources/DustlingAppModel/Mosaic/MosaicLayout.swift`
  - `Sources/DustlingAppModel/Goal/UpdateGoal.swift`
- Test: `Tests/DustlingAppModelTests/MosaicLayoutTests.swift`, `UpdateGoalTests.swift`, `BytesTests.swift`

**Interfaces:**
- `public enum CellKind: Hashable, Sendable { case free, category(JunkCategoryID), inTrash, locked, other }`
- `public struct MosaicLayout: Equatable, Sendable { cells: [CellKind]; rows: Int = 4; columns: Int; public static func make(totalBytes: Int64, availableBytes: Int64, categories: [(JunkCategoryID, UInt64)], inTrashBytes: UInt64, lockedPlaces: Int, cellBytes: UInt64 = 268_435_456) -> MosaicLayout }`
  - One cell = 0.25 GiB, i.e. 268,435,456 bytes, because the design's "quarter gigabyte" pairs with binary display. Ruling R31.
  - Cells are ordered: free, then categories (largest first), then inTrash, then locked (one cell each), then other.
  - Rounding: a category with bytes > 0 gets at least 1 cell. The total is the ceiling of each part, and `other` absorbs the difference down to 0.
- `public enum CategorySeries { public static func slot(for: JunkCategoryID) -> Int }`. The mapping, verbatim from DESIGN-mosaic §2:
  - xcodeJunk → 1
  - systemCachesAndLogs → 2
  - userCaches → 3
  - packageManagerCaches → 4
  - userLogs → 5
  - browserCaches → 6
  - review categories (oldInstallers, iosBackups, xcodeArchives, largeOldDownloads, mailDownloads) → 7
  - trash → nil (neutral)
- `public struct UpdateGoal: Codable, Equatable, Sendable { var neededBytes: Int64; var source: Source }` with `enum Source { case userSet, measured(Date) }`. Default `neededBytes = 30 GB` (decimal, matching Finder).
  - `public static func measure(commands: CommandRunning) throws -> Int64?` parses `/usr/sbin/softwareupdate --list` "Size: NNNNKiB" lines.
  - It runs ONLY when the user clicks "Check update size". That is a user-initiated system tool call, not part of cleaning (Ruling R32).
- `public func shortfall(available: Int64) -> Int64` returns max(0, needed − available).
- [ ] Tests:
  - `freeCellsComeFirstThenLargestCategory`
  - `tinyCategoryGetsOneCell`
  - `inTrashCellsAreHatchedUntilEmptied` (inTrash cells present, free unchanged)
  - `lockedPlacesRenderAsLockedNotZero`
  - `columnsAreCeilOfCellsOverFour`
  - `parsesSoftwareupdateSize`
  - `shortfallNeverNegative`
  - the bytes formatter cases moved from the CLI, including the "1000 KB" boundary fix (999,999 bytes → "1 MB")
- [ ] Implement, `swift test`, commit `feat(model): app model target with mosaic layout and update goal`.

### Task 6: Health and storage models

**Files:**
- Create: `Sources/DustlingAppModel/Health/HealthModel.swift`, `Sources/DustlingAppModel/Health/StorageModel.swift`
- Test: `Tests/DustlingAppModelTests/HealthModelTests.swift`

**Interfaces:**
- `@MainActor @Observable public final class HealthModel { fullDiskAccess: FullDiskAccessStatus; lastRunProblem: String?; helper: HelperStatus = .notAvailable; lights: [HealthLight]; init(probe: @escaping @Sendable () -> FullDiskAccessStatus, clock: some Clock<Duration>); func startPolling(interval: Duration = .seconds(2)); func stopPolling(); func appBecameActive() }`.
  - `HelperStatus` has `notAvailable` ("coming in a later version"), plus `ok`, `needsApproval` and `notResponding` reserved for Plan 2.
  - `HealthLight { kind: .fullDiskAccess | .helper | .lastRun; state: .ok | .warning; detail: String; fix: FixAction? }`.
- `@MainActor @Observable public final class StorageModel { info: StorageInfo?; purgeableBytes: Int64; problems: [String]; func refresh() async }` uses `StorageReader`.
- [ ] Tests:
  - `fdaPollingFlipsToGrantedWithoutRestart` (Review Focus 1): a fake probe flips on the 3rd call; a test clock advances 6 s; the status is `.granted`.
  - `appBecameActiveReprobes`
  - `lostAccessTurnsLightAmber`
  - `purgeableIsClampedAtZero`
- [ ] Implement, test, commit `feat(model): health and storage models`.

### Task 7: Junk scan model, including Empty Trash and Restore

**Files:**
- Create: `Sources/DustlingAppModel/JunkScan/JunkScanModel.swift`, `Sources/DustlingAppModel/Trash/TrashModel.swift`
- Test: `Tests/DustlingAppModelTests/JunkScanModelTests.swift`, `TrashModelTests.swift`

**Interfaces:**
- `@MainActor @Observable public final class JunkScanModel`
  - `state: .idle | .scanning(ScanProgress) | .ready | .moving(done: Int, total: Int, bytes: UInt64) | .done(RunRecord) | .problem(String)`
  - `categories: [CategoryTileModel]`, where `CategoryTileModel { id, title, note, bytes, itemCount, selection, isSelected, stopped, issues: [ScanIssue], inUseCount }`
  - `selectedBytes`
  - `func scan(); func stop(); func toggle(_ id:); func clean() async; func putEverythingBack() async throws -> [RestoreOutcome]`
  - Injected engine pieces: `JunkScanner`, `CleanupRunner`, `RunJournal`, and an `environment`.
  - Preselection follows `Selection.preselected` plus the Settings "Preselect safe categories" toggle. Review categories always start unchecked. iOS backups carry the note "Your data, never selected for you".
- `@MainActor @Observable public final class TrashModel { contents: (size: SizeResult, issues: [ScanIssue])?; canEmpty: Bool; disabledReason: String?; inTrashBytesSinceLastEmpty: UInt64; func refresh(); func emptyTrash() async -> RunRecord }`.
  - `canEmpty` is false when any trash location is unreadable or the size is 0. The reason is in plain words.
- [ ] Tests:
  - `scanFillsTilesAsCategoriesFinish`
  - `stopMarksPartialCategory` (model surfaces `stopped`)
  - `reviewCategoriesStartUnchecked`
  - `summaryUsesActualOutcomes` (Review Focus 3: fake runner with 2 moved, 1 skipped, 1 failed → the summary bytes equal the moved bytes, and the skipped and failed reasons are exposed)
  - `putEverythingBackRestoresOnlyMovedItems`
  - `emptyTrashDisabledWhenTrashUnreadable` (Review Focus 4)
  - `inTrashBytesFeedMosaicUntilEmptied`
- [ ] Implement, test, commit `feat(model): junk scan and trash models`.

### Task 8: Uninstaller, startup and history models

**Files:**
- Create: `Sources/DustlingAppModel/Uninstaller/UninstallerModel.swift`, `Sources/DustlingAppModel/Startup/StartupModel.swift`, `Sources/DustlingAppModel/History/HistoryModel.swift`
- Test: `Tests/DustlingAppModelTests/UninstallerModelTests.swift`, `StartupModelTests.swift`, `HistoryModelTests.swift`

**Interfaces:**
- `UninstallerModel`
  - `apps: [AppRow]` with `{ app, leftoverCount, totalBytes, label: "Steam game" | "Shortcut" | nil }`, plus `selection: Set<URL>`.
  - `leftovers(for:) -> [LeftoverRow]` with `{ leftover, checked, badges: [.teamID, .helper, .nameMatch, .yourData], warning: String? }`.
  - Checking a `yourData` row sets `warning` to the verbatim text "This is your data. <what>. You can put it back from the Trash, but not after you empty it."
  - `confirmation -> ConfirmModel { perApp: [(name, items, bytes)], dataWarnings, runningApps, totalBytes }`.
  - `uninstallSelected(quit: AppQuitter) async -> [RunRecord]`. Uninstalls app by app. A running app that doesn't quit within 10 s is recorded as skipped "still running" and the others proceed.
  - `among:` excludes the target and its nested apps.
- `StartupModel`
  - Groups: loginItems, agents, daemons. Each group has an `onCount/total` and a `filter`.
  - `toggle(item) async -> RunRecord` (via `StartupChangeRecorder`).
  - Daemons are disabled with the chip "Needs the cleanup helper". Login-only items show the "In System Settings" link.
  - Orphan detection: an item whose `program` path no longer exists, or whose owner app isn't installed, gets an "orphaned" banner model.
- `HistoryModel`
  - `runs` (timeline, newest first, with a `restorable` chip), `lastEmptyTrash: Date?`, `allItems` (searchable, Restorable/All filter).
  - `logLines(for runID) -> [LogLine]` parsed from the run record, not the text log.
  - `restore(runID, paths?) async throws -> [RestoreOutcome]`.
- [ ] Tests:
  - `checkingDataRowShowsWarning`
  - `confirmationSeparatesDataItems`
  - `runningAppThatWontQuitIsSkippedOthersProceed` (Review Focus 5)
  - `daemonsDisabledWithoutHelper`
  - `orphanedItemDetected`
  - `historyMarksRunsBeforeLastEmptyAsNotRestorable`
  - `searchFiltersAllItems`
- [ ] Implement, test, commit `feat(model): uninstaller, startup and history models`.

## Part C: the app

### Task 9: App project, theme, fonts, icon, shell

**Files:**
- Create:
  - `App/project.yml` (XcodeGen). Target `Dustling`: macOS app, deployment target 14.0, bundle id `app.dustling.Dustling`, local package `..` with products `DustlingCore` and `DustlingAppModel`, `ENABLE_HARDENED_RUNTIME = YES`, no sandbox, `CODE_SIGN_STYLE = Automatic`, includes the optional `App/Local.xcconfig`.
  - `App/Dustling/DustlingApp.swift`
  - `App/Dustling/Theme/DustlingTheme.swift` (copied verbatim from the handoff)
  - `App/Dustling/Resources/Fonts/*.ttf` + `OFL-*.txt`
  - `App/Dustling/Resources/Assets.xcassets/AppIcon.appiconset` (from the logo kit)
  - `App/Dustling/Shell/{RootView,Sidebar,SidebarFooter,Toolbar,ActionBar,Banner,Chip,MoteView,PixelIconView,Skeleton}.swift`
  - `App/.gitignore` (`*.xcodeproj`, `Local.xcconfig`, `build/`)
  - `App/README.md` (build steps)
- Modify: root `README.md` (an "Build the app" section).

**Details:**
- **Fonts:**
  - Geist, Geist Mono and Geist Pixel come from the official `vercel/geist-font` GitHub release.
  - Pixelify Sans comes from `google/fonts` `ofl/pixelifysans`.
  - The implementer downloads them ONLY after the controller confirms Kaan's OK. These are file downloads from GitHub; record the URL and SHA-256 of each in `App/Dustling/Resources/Fonts/SOURCES.md`.
- **Shell:**
  - NavigationSplitView with a 236 pt sidebar containing Home, Junk scan, Uninstaller, Startup items and History.
  - Sidebar footer: storage meter, available/total, "The macOS update needs N GB", the three health lights (popover), and a Settings link.
  - Toolbar: 56 pt, pixel title and subtitle.
  - Action bar: 60 pt.
- **MoteView:** faces idle, sniff (walk + bob), chomp, happy (hop once), worried, sleepy (breathe). Driven by `TimelineView(.periodic)`, stopped under Reduce Motion or when the window isn't key.

**Steps:**
- [ ] Run `cd App && xcodegen generate && xcodebuild -scheme Dustling -configuration Debug build`. Expected: BUILD SUCCEEDED.
- [ ] Launch the built app. Take screenshots of the empty shell in light and dark (`screencapture -l <windowid>`) and compare them against the shell in the "Your mix" reference.
- [ ] Commit `feat(app): Xcode project, Mosaic theme, fonts, icon and app shell`.

### Task 10: Onboarding and limited mode

**Files:** `App/Dustling/Onboarding/{OnboardingWindow,WelcomeStep,FullDiskAccessStep,PermissionsStep,ReadyStep}.swift`, `App/Dustling/Home/LimitedModeBanner.swift`

**Details:**
- Follow SCREENS-final §1 exactly: the four steps, the step list footer copy, the trust panels, the locked mosaic, "Open System Settings" (deep link), and the drag tile.
- The drag tile uses an `NSItemProvider` for the app bundle URL.
- The live status line comes from `HealthModel.startPolling`.
- The Helper row shows "Not available yet" per the Global Constraints.
- Notifications row: omitted (Ruling R33: the Trash-size notification needs background monitoring, which is out of v1 scope).
- Shown on first launch and from Settings > Permissions.

**Steps:**
- [ ] Build.
- [ ] Manual check: start with Dustling's own Full Disk Access entry switched off. Turn it on while the onboarding is open. The status flips within 2 s with no relaunch.
- [ ] Screenshots of all steps (light and dark).
- [ ] Commit.

### Task 11: Home

**Files:** `App/Dustling/Home/{HomeView,HeroPanel,GoalMeter,MosaicView,ToolCard,PurgeableBanner}.swift`

**Details:**
- Follow SCREENS-final §2.
- **Hero:** "You need N GB more for the macOS update", or the goal-met state, with **Clean up junk** (primary) and **Empty Trash… N GB**.
- **Goal meter:** 45 segments.
- **MosaicView:** draws `MosaicLayout` with `Canvas`. Hatched cells for inTrash and locked. Hover-link with tool rows. Nibble animation per DESIGN-mosaic §5, gated by Reduce Motion.
- **Tool cards:** the three tool cards.
- **Purgeable banner:** shown when purgeable plus snapshots ≥ 2 GB, with the plain-words copy from spec §7.2b.
- "Check update size" sits next to the goal (Ruling R32).

**Steps:**
- [ ] Build, then manual run on the real Mac with FDA granted.
- [ ] Screenshots: normal and goal-met (the goal-met state is forced via a debug `UpdateGoal`).
- [ ] Commit.

### Task 12: Junk scan screen and Empty Trash sheet

**Files:** `App/Dustling/JunkScan/{JunkScanView,ScanHeader,CategoryTile,TrashTile,SummaryView}.swift`, `App/Dustling/Trash/EmptyTrashSheet.swift`

**Details:**
- Follow SCREENS-final §3.
- **Scanning:**
  - Skeleton tiles, Mote sniffing, the path ticker, "N of 12 places done", the live counter, and **Stop**.
- **Results:**
  - Two sections, a 3-column tile grid, and a mini mosaic per tile.
  - Partial tiles say "scan stopped".
  - Locked tiles say "couldn't scan, needs Full Disk Access".
- **Moving:**
  - Per-tile spinner → check, and nibble.
- **Summary:**
  - Happy Mote and a count-up, from RunRecord outcomes only.
  - The skipped and failed reasons listed.
  - **Empty Trash… N GB**, **Put everything back**, **View log**.
- **EmptyTrashSheet:**
  - Lists the top items, capped at 50 with "…and N more".
  - The total in red text, and a destructive button.
  - Disabled with the reason when `TrashModel.canEmpty` is false.

**Steps:**
- [ ] Build, then manual run: scan → stop mid-way → rescan → clean a small selection (e.g. only `userLogs`) → Put everything back.
- [ ] Verify the restored files are back.
- [ ] Screenshots of each state.
- [ ] Commit.

### Task 13: Uninstaller screen

**Files:** `App/Dustling/Uninstaller/{UninstallerView,AppListRow,LeftoverRow,UninstallConfirmSheet,RemovingView}.swift`

**Details:**
- Follow SCREENS-final §4.
- **Panes:** the two panes.
- **Badges:** the badge set.
- **Data rows:** the data-row warning tint and inline text.
- **Confirm sheet:** "Move N apps to the Trash?", with a separate data-warning block and "Quit <app> and move to Trash".
- **Removing state:** app by app.
- **AppQuitter:** uses `NSRunningApplication.terminate()`, then waits up to 10 s.
- **Footer:** "Documents you made with <app> are never touched."

**Steps:**
- [ ] Build, then manual run: select a Steam shortcut (e.g. Portal) and confirm the leftovers view. Do NOT confirm the uninstall.
- [ ] Uninstall a throwaway test app copied to `~/Applications/DustlingTest.app`, then restore it from History.
- [ ] Screenshots.
- [ ] Commit.

### Task 14: Startup items and History screens

**Files:** `App/Dustling/Startup/{StartupView,StartupRow,OrphanBanner}.swift`, `App/Dustling/History/{HistoryView,RunsTimeline,AllItemsTable,LogTab}.swift`

**Details:**
- Follow SCREENS-final §5 and §6.
- **Startup:**
  - A toolbar filter, group headers with "N of M on", and switches.
  - The "In System Settings" badge links to `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`.
  - Daemons are disabled with the helper chip.
  - Remove is secondary, confirms first, and moves the plist to the Trash via `CleanupRunner` with kind `.startupChange`.
- **History:**
  - Three tabs (Runs, All items, Log), and a dashed line at the last Empty Trash.
  - **Show log file in Finder** and **Copy for a bug report** (the copied text is the run's log lines).

**Steps:**
- [ ] Build, then manual run: toggle one harmless user agent off and on again.
- [ ] Verify that two `.startupChange` runs appear in History.
- [ ] Screenshots.
- [ ] Commit.

### Task 15: Settings, errors and repair

**Files:**
- `App/Dustling/Settings/{SettingsWindow,GeneralSection,ScanningSection,ExclusionsSection,PermissionsSection,AboutSection}.swift`
- `App/Dustling/Health/{HealthLightsPopover,BlockerSheet,DiagnosticsView}.swift`
- `Sources/DustlingAppModel/Settings/AppSettings.swift` (`@Observable`, persisted with `UserDefaults`)

**Details:**
- Follow SCREENS-final §7 and §8: one scrolling page with sidebar jump-links.
- **General:**
  - Open at login uses `SMAppService.mainApp`.
  - "Always confirm before Empty Trash" is locked on.
  - Appearance.
  - The "Show in the menu bar" and Trash-size notification toggles are omitted (R33).
- **Scanning:** maps to `ScanOptions` (Task 4).
- **Exclusions:**
  - A folder list using `NSOpenPanel`.
  - Always-protected folders shown as locked chips.
- **About:**
  - Version, MIT, a GitHub link and the logs folder. No update check (no network).
- **Diagnostics:**
  - **Copy diagnostics report** contains the macOS version, app version and check results. It must contain no home-folder file names; test this in AppModel: `diagnosticsReportHasNoHomePaths`.
- **Blocker sheet:** only for blocking cases, such as FDA lost before a scan.

**Steps:**
- [ ] Add the `diagnosticsReportHasNoHomePaths` test to `DustlingAppModelTests`, then run `swift test`.
- [ ] Build, then manual check of each section and the three repair cases from SCREENS-final §8. The helper case shows the "not available yet" state.
- [ ] Screenshots.
- [ ] Commit.

### Task 16: End-to-end verification and polish

- [ ] Run `swift test` (all suites) and `xcodebuild … build` with zero warnings in the app target.
- [ ] Run the app with Reduce Motion on: no animated Mote, no stagger, instant values, static "Moving…".
- [ ] Run the app with Increase Contrast and in Dark mode. Take screenshots of every screen in light and dark, and put them in `docs/screenshots/`.
- [ ] Accessibility pass:
  - Every control has a label, and tiles read their name, size and selection state.
  - Keyboard navigation works across sidebar, tiles and lists.
  - VoiceOver reads the mosaic as a summary ("Reclaimable: 15 GB in 6 categories; 5 places locked").
- [ ] Root README: replace the "Status" note, add screenshots and the "Build the app" section.
- [ ] Commit `docs: app screenshots and README`.

---

## Done when

- All `swift test` suites pass, and the app builds with no warnings.
- Every screen in SCREENS-final is implemented and screenshot-verified against the approved "Your mix" frames, in light and dark.
- Review Focus 1–5 are each covered by a test, and the manual checks above are recorded in the PR.
- No helper-dependent control pretends to work. No "0 bytes" where Dustling couldn't look. Every outcome is visible in the UI and in History.

## Rulings in this plan (for Kaan to veto)

- **R31:** a mosaic cell = 0.25 GiB (binary), to match the byte formatter.
- **R32:** the "macOS update needs N GB" goal defaults to 30 GB and is user-editable. "Check update size" runs `softwareupdate --list` only when clicked.
- **R33:** "Show in the menu bar" and the Trash-size notification are left out of v1. A menu bar monitor and background monitoring are spec non-goals.
- **R34:** the app is generated with XcodeGen (`App/project.yml`), not a checked-in `.xcodeproj`. The project file stays reviewable and conflict-free.
- **R35:** fonts are downloaded from the official GitHub sources (vercel/geist-font, google/fonts) when Task 9 runs. This needs Kaan's OK first, since it downloads files.
