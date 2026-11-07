# Dustling: design

Date: 2026-11-07
Owner: Kaan
Status: approved by Kaan 2026-11-07

## 1. Intent

Kaan tried to install a macOS update and couldn't, because the disk was full. There was no easy way to see what was taking the space, or to remove apps cleanly along with their leftovers. He uses CCleaner, but it sometimes silently does nothing even with every permission granted, and the only fix is to reinstall it.

Dustling is a free, open-source, native macOS cleaner that does three jobs well and **never fails silently**. "Dustling" is the name, and its mascot is a tiny pixel dust creature that eats junk. The mascot shows up in the icon, empty states and the scanning animation.

Success looks like this: on a nearly full Mac, Kaan opens Dustling, sees in seconds where the space went, frees enough of it for a macOS update, and trusts that what the app says happened really did happen.

## 2. Goals (v1)

1. **App Uninstaller.** List the installed apps. Remove one or many at once, together with their related leftovers (caches, preferences, support files, containers, launch agents, helpers, receipts), but never the user's own documents.
2. **Startup Items.** Show what launches at login or runs in the background (login items, launch agents and launch daemons), and let the user turn each one off.
3. **Junk Scan.** Find unnecessary files, show how much space each category takes, and let the user clean them.
4. **Trust and safety.** Preview everything before deleting, move to Trash by default, log every action, and report every per-item failure with its reason.
5. **Polished feel.** Skeleton loaders, per-item progress, animated results and smooth transitions, all of which honor Reduce Motion.

## 3. Non-goals (v1)

- Duplicate finder, similar photos, disk space map or treemap, menu bar monitor, RAM "optimizer", scheduled or automatic cleaning, malware scanning. These may come later; Kaan will add features when he thinks of them.
- Watching Finder for apps dragged to the Trash (CCleaner does this).
- Localization. The app is English only.
- Accounts, licensing, telemetry, analytics, ads, upsells.
- App Store distribution. Full Disk Access and an admin helper rule out the sandbox.

## 4. Anti-goals (a failure even if it technically works)

- **Silent failure.** A cleanup that reports success but deleted nothing. A button that does nothing. A feature that stops working until reinstall. This is the #1 thing Kaan hates in CCleaner.
- **Deleting something the user didn't see and approve.** That includes anything in Documents, Desktop, Pictures, Music, Movies or iCloud Drive, or anything SIP protects or under `/System`.
- **Scareware tone.** No "your Mac is at risk!", no inflated numbers, no fake urgency.
- **Motion that slows the user down or exists just for show.**
- **Vague errors** like "Something went wrong" with no reason and no next step.

## 5. Constraints and decisions already made

| Topic | Decision | Source |
|---|---|---|
| Platform | Native macOS app, Swift + SwiftUI (AppKit where SwiftUI falls short) | Claude's call, Kaan didn't object |
| Minimum OS | macOS 14 Sonoma | Claude's call |
| Language | English only | Kaan |
| License and distribution | Open source on GitHub, MIT, `.dmg` via GitHub Releases, Homebrew cask, plus a landing page (separate thread) | Kaan (open source + landing page); Claude (MIT, dmg, Homebrew) |
| Signing | Build and test locally for now. Kaan will buy the Apple Developer account later for Developer ID signing and notarization | Kaan |
| Deletion default | Everything goes to the Trash first | Kaan approved |
| Network | Cleaning never needs the network. No telemetry | Claude's call |
| Design | Visual theme chosen in the thread "Choose the cleaner app's design theme". Every main screen then gets about 10 variants in that theme (made with Impeccable, taste, Hallmark, Hue, better-typography and Apple HIG, synthesized where helpful), and Kaan picks before any UI is built | Kaan |

## 6. What we learned from CCleaner (reference only, no code or assets copied)

Static inspection of an installed copy of CCleaner 2.11 (REA Mach-O inspection plus bundle and strings analysis) and its logs:

- **Modules:** quick clean, browser clean, app uninstaller, disk analyzer, duplicates, similar photos, startup manager, system monitor, menu bar.
- **Cleaning targets:** user caches and logs, sandboxed app containers, `/private/var/folders`, Trash including external drives' hidden trashes, empty folders, large files. The uninstaller removes Preferences, Saved Application State, LaunchAgents and LaunchDaemons, PrivilegedHelperTools and pkg receipts.
- **Architecture:** normal deletes happen in-process, and privileged deletes go over XPC to root launch daemons. It uses the older Authorization Services APIs and the deprecated `LSSharedFileList` for login items. It scans with `fts`.
- **Why it can silently stop working:** the cleaning engine's LaunchDaemon plist exists (`/Library/LaunchDaemons/com.piriform.ccleaner.engine.xpc.plist`), but the service isn't loaded in launchd's system domain. Privileged requests get no answer, and reinstalling re-registers it. Its logs contain **no** deletion-failure entries, so the failure is invisible at every level.
- **Its uninstaller skips apps with no bundle ID or name in Info.plist**, including Steam game wrappers in `~/Applications`.

Each of these becomes a requirement below.

## 7. Product behavior

### 7.1 First run and permissions

- A short onboarding explains why Full Disk Access is needed. It shows a clear "Open System Settings" button that deep-links to Privacy & Security → Full Disk Access, plus a visual hint of what to toggle.
- **Real verification:** Dustling doesn't trust a flag. It checks access by attempting to read a TCC-protected location, and it notices automatically (by polling or on app activation) when access is granted. No restart prompt unless macOS truly requires one.
- The admin helper (for root-owned items such as `/Library/LaunchDaemons` and `/Library/Caches`) is registered with **`SMAppService`**. If macOS needs the user to approve it in System Settings → Login Items & Extensions, Dustling says so and links there.
- **Without Full Disk Access** the app still works in a reduced mode. It clearly marks which categories it couldn't scan and why. It never shows a "0 bytes" result that is really a permission problem.

### 7.2 Health checks: the "never fail silently" core

On every launch and before every destructive action:
- Re-verify Full Disk Access with a real read.
- Check the helper's `SMAppService` status and ping it over XPC. If it isn't registered or isn't responding, try to re-register it automatically. If that fails, show a banner with a **Repair** button and a plain explanation.
- Note for local development: TCC grants are tied to the code signature, so each ad-hoc rebuild can silently invalidate Full Disk Access. The health check has to catch exactly this case.

Every deletion yields a per-item result: `moved to Trash`, `deleted`, `skipped: in use by <app>`, `failed: <reason>`, or `needs admin`. The results screen shows totals that come from what actually happened, not from what was planned.

Every run is written to a human-readable log in `~/Library/Logs/Dustling/`, including each attempted path and its result. An in-app **History** view lists past runs.

**Restore (the undo Kaan was promised).** Finder's "Put Back" doesn't work for files trashed programmatically, and bulk-trashed folders collide on names. So History also keeps a durable record of *original path → Trash path* for every item, and offers **Restore** for a whole run or for individual items, as long as they're still in the Trash. Once the Trash is emptied, History marks those runs as no longer restorable.

### 7.2a Deletion rules (the safety line)

- **Normal cleaning and uninstalling only ever move items to the Trash.** Nothing is permanently deleted as part of a clean.
- **Root-owned items:** the helper moves them into the user's Trash and changes their owner to the user, so they can be emptied and restored like any other item. No password prompt from Finder, and no separate admin-only Trash.
- **The only permanent deletion is Empty Trash.** It's an explicit action that shows the size first and asks for confirmation. It's the step that actually frees space, so after any clean the summary offers it prominently.
- There is no "delete immediately" setting in v1.
- Result states: `moved to Trash`, `skipped: in use by <app>`, `failed: <reason>`, `needs admin`. `deleted` appears only for items removed by Empty Trash.

### 7.2b Home and the storage number

- The storage bar uses the same "available" figure macOS uses for updates (`volumeAvailableCapacityForImportantUsage`), so Dustling agrees with the updater and Finder.
- Home shows used and available space, plus what each of Dustling's three tools can reclaim. It doesn't attempt a full-disk breakdown, because a disk map is a non-goal for v1.
- **Explain, don't hide:** if a meaningful amount of space is held by local Time Machine snapshots or is "purgeable", Home says so in plain words, explains that macOS manages it, and explains why emptying the Trash may not immediately free it. v1 doesn't delete snapshots.

### 7.3 Junk Scan

- **Scanning:** skeleton rows fill in as categories finish, and a live "space found" counter ticks up. Scanning is cancellable.
- **Results** are grouped by category, with size and item count, and expand down to individual files. Each category is either **preselected** (safe to regenerate) or **review** (shown, unchecked).
- **Starting category set** (the builder may refine it, but must keep the safe/review split):
  - Preselected: user caches (`~/Library/Caches`, app container caches), user logs, system caches and logs (admin), browser caches only (Safari, Chrome, Firefox, Edge, Brave, Arc), Xcode DerivedData and old simulator caches, package manager caches (Homebrew, npm, pip, CocoaPods and similar).
  - **Trash row (Kaan):** what's already in the Trash, including external volumes, appears in the same results list as its own row. It has the system trash icon, its size and an **Empty Trash…** button right on the row. It's never part of a normal clean, and Empty Trash always confirms first. It uses Apple's standard name "Empty Trash" so it's instantly recognizable. Claude's call, at Kaan's invitation to pick the name.
  - Review: Also review: old installers (`.dmg` and `.pkg` in Downloads), iOS device backups, Xcode Archives, large or old files in Downloads, Mail downloads.
  - Never: browser history, cookies or passwords. Anything in the user's personal folders except the explicit review items above.
- **Space-freeing honesty:** moving files to the Trash doesn't free disk space. After cleanup, the summary says "X GB moved to Trash" and offers a one-click **Empty Trash** with a confirmation. The storage bar shrinks only once space is really freed. Kaan's goal is freeing space for an update, so this step must be obvious.
- Before cleaning, warn about running apps whose caches are in use, and offer to quit them.

### 7.4 App Uninstaller

- **Discovery:** `/Applications`, `~/Applications` and their subfolders. That includes apps with **no bundle ID or name** (for example Steam game wrappers), identified by bundle name, executable name or folder name. Apple system apps in `/System/Applications` are never listed.
- **The list** shows icon, name, size including leftovers, and last-used date where available. It is searchable and sortable, and supports multi-select.
- **Leftover detection** across the standard locations: Application Support, Caches, Preferences (including ByHost), Containers, Group Containers (by team ID), Saved Application State, HTTPStorages, WebKit, Logs, Cookies, LaunchAgents and LaunchDaemons (matched by the program path they point to), PrivilegedHelperTools, login items, and pkg receipts (`pkgutil`).
  - Exact bundle-ID or team-ID matches are **preselected**. Name-based (fuzzy) matches are shown but **unchecked**.
  - **"May contain your data" (Kaan):** leftovers that look like the user's own content stay **unchecked** by default. That covers game saves, note or app databases, media libraries and project files, typically found in Application Support, Containers or Group Containers. They're marked with a clear badge. Checking one shows a **warning** that this is the user's data and may not be recoverable once the Trash is emptied. The confirmation screen lists any checked data items separately, with that warning. Caches, preferences and logs are still preselected.
  - For Steam games, also surface the game's data in Steam's library folder as a review item.
- **Confirmation** shows everything that will move to the Trash, with sizes. If an app is running, offer to quit it first.
- **Removal** goes app by app with per-item progress, and launch agents and daemons are unloaded before their files are removed.

### 7.5 Startup Items

- Show three groups: Login Items, Launch Agents (user and system), and Launch Daemons. Each row shows the owning app (when it can be determined), status, and where it lives.
- **The primary action is disable or enable** (reversible). Removing a startup item entirely is a secondary action with confirmation.
- Root-level items go through the helper.
- **Known risk:** macOS doesn't offer a full public API for listing other apps' login items (the Background Task Management database). The plan must begin with a short research spike, and the UI must say plainly when an item can only be managed in System Settings. It should link there rather than pretend.

### 7.6 Motion and feel

Skeleton loaders while scanning. A spinner that turns into a checkmark, or a clear error, for each item during deletion. An animated "space recovered" summary. A storage bar that visibly shrinks. Smooth insert and remove transitions in lists. Hover and press states on every control. A subtle progress ring for long jobs. The mascot appears in empty states and the scan animation. Everything respects **Reduce Motion**, and nothing blocks input to finish an animation.

## 8. Architecture (decided at the level that matters)

- **App process (SwiftUI):** UI, scanning of user-level locations, moving user-owned files to the Trash.
- **Privileged helper (launch daemon via `SMAppService`, talking over XPC):** handles only root-owned paths. It validates that the caller is Dustling (code-signing requirement) and enforces the same protected-path denylist on its side.
- **Helper caller check:** the helper accepts connections only from a Dustling build signed with the expected **Team ID**. Ad-hoc signatures have no Team ID, so the helper is never enabled in ad-hoc builds. For local development, builds are signed with a free Apple ID "Personal Team" certificate. That gives a stable Team ID, and Full Disk Access survives rebuilds. Release builds use Developer ID once Kaan buys the account.
- **One shared "protected paths" denylist,** enforced in both processes: `/System`, SIP-protected locations, the user's personal folders except explicitly allowed review items, other users' homes, and anything outside the declared category roots.
- **Scanning engine:** fast directory walking (`fts` or the `FileManager` enumerator with prefetching of resource keys), cancellable, with sizes using allocated size.

## 9. Design process (gates before UI code)

1. **Theme:** picked by Kaan in the design thread "Choose the cleaner app's design theme".
2. **Screens:** about 10 variants each, in the chosen theme, synthesized where useful. Kaan picks one per screen:
   - Onboarding and permissions
   - Home and overview (storage bar plus the three tools)
   - Junk Scan (scanning, results, cleanup summary)
   - App Uninstaller (list, leftovers detail, confirmation, progress)
   - Startup Items
   - History, Settings, error and repair states
   - App icon and mascot
3. **Landing page:** a separate thread after the theme is chosen. It offers the download from GitHub Releases plus a Homebrew command.

## 9a. Repositories and releases (Kaan)

- **Two repos:** the app is **public** on GitHub, open source under MIT. The website at dustling.app is a **separate private repo**.
- The app repo follows normal open-source practice: README with screenshots and install steps, CHANGELOG, CONTRIBUTING, issue and PR templates, and the design docs in `docs/`.
- **Versioned releases:** semantic versions (v0.1.0, v0.2.0, …), each with a GitHub Release, release notes describing what changed, and the `.dmg` attached. The website sends users to the latest release and to the repo.

## 9b. Phases

1. **Phase 1, local (now):** the engine, helper and app run from local builds on the developer's Mac, signed with a free Personal Team certificate. Engine and helper work can start while the design thread runs. UI is built only after the screen picks.
2. **Phase 2, public release (after the Apple Developer account):** Developer ID signing, notarization, a `.dmg` on GitHub Releases, and a Homebrew cask (the main Homebrew repo increasingly requires apps that pass Gatekeeper). Auto-update is out of scope for v1. Users update from GitHub or through Homebrew, which keeps the no-network rule intact.

## 10. Left to the builder

- Module and package layout, the test strategy (TDD per the Superpowers workflow), concurrency model and persistence for history.
- Exact cache paths per browser and tool, and size-calculation details.
- How "last used" is determined.
- Fine-tuning the category list within the safe/review/never rules.
- Calls Claude made that Kaan can veto: Swift + SwiftUI, macOS 14+, MIT, `.dmg` + Homebrew, the no-network rule, the safe/review/never split, and the shape of the Empty Trash step.
