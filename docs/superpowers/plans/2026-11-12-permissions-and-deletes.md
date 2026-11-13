# Full Disk Access That Sticks, and Honest Deletes: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full Disk Access survives updates and Dustling says exactly why when macOS holds it for another copy; Empty Trash and cleanups never fail silently, fix what the user owns, and explain what needs an administrator or what macOS protects.

**Architecture:** Release builds are re-signed with one long-lived self-signed certificate, so the designated requirement macOS's privacy database (TCC) stores is `identifier "app.dustling.Dustling" and certificate leaf = H"…"` instead of a per-build cdhash. Debug builds get their own bundle ID so they never collide with the installed app's grant. The app remembers the designated requirement that last had access and tells "a different copy" from "switched off". Emptying the Trash unlocks the user's own locked items and classifies what's left.

**Tech Stack:** Swift 6, SwiftUI, macOS 14+, Swift Testing, XcodeGen, Security.framework (`SecCodeCopySelf`), bash, openssl, GitHub Actions.

**Spec:** this plan (the bug report and evidence are in "Root causes" below; the product design is `docs/superpowers/specs/2026-11-07-dustling-design.md` and `SCREENS-final.md`).

## Root causes (evidence, 2026-11-12)

- tccd log on the user's Mac: `Failed to match existing code requirement for subject app.dustling.Dustling and service kTCCServiceSystemPolicyAllFiles`, stored `cdhash H"66c26c3b…"` (the 0.1.2 build) vs running `cdhash H"d67c1ca0…"` (/Applications 0.1.1) and `cdhash H"07dd4505…"` (a Debug build in `App/build`, same bundle ID). Ad-hoc signing makes the designated requirement the cdhash, so every build and every copy is a different app to macOS while System Settings still shows "Dustling" switched on.
- Verified: two different builds signed with the same self-signed certificate satisfy each other's designated requirement (`codesign -v -R=<DR of A> B` exits 0; ad-hoc exits 3). Gatekeeper's verdict is the same as for ad-hoc builds (rejected until "Open Anyway"; neither is notarized).
- Empty Trash: five "TI …" apps (installed by a package whose files belong to uid 503, group wheel, mode 775) fail with "you don't have permission" on every try, and `EmptyTrashSheet` dismisses itself on `.emptied` even when entries failed, so nothing tells the user.
- `~/Library/Caches/com.apple.textunderstandingd` fails to move with EPERM although `access()` allows it (its `Private` folder is protected by macOS).

## Global Constraints

- English only; plain sentences in UI copy, no jargon ("designated requirement", "cdhash", "TCC" never appear in the app).
- Nothing is ever deleted except by Empty Trash, after its confirmation. Never follow symlinks when changing permissions or deleting.
- Every item a run touches ends in the journal with an outcome; nothing fails silently.
- Version lives only in `App/project.yml` `MARKETING_VERSION`; user-visible changes get a line under `## [Unreleased]` in `CHANGELOG.md`.
- The signing private key is never committed. Only the public certificate and its SHA-1 are in the repo.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) and `TestSandbox` / `ScratchDefaults` as the existing tests do. `swift test` must pass.

## Review Focus

- A user who granted access to 0.1.2, then opens 0.1.1 or a Debug build: the app must say "this copy is different", not "you switched it off" (Task 3 test `lossCauseIsNewCopyWhenRequirementDiffers`).
- Existing installs whose defaults have `fullDiskAccessWasGranted = true` but no stored requirement: must get the cause-neutral copy, never crash or claim a cause (Task 3 test `legacyFlagWithoutRequirementIsUnknownCause`).
- A Trash item that is a symlink to a locked folder outside the Trash: unlocking must never touch the target (Task 4 test `unlockNeverFollowsSymlinks`).
- A Trash item with a mix of the user's locked files and another account's files: the user's part is deleted, the rest is reported as needing an administrator with the right count (Task 4 test `mixedOwnershipReportsNeedsAdmin`).
- A release tag built without the signing secret, or with a different certificate: the build must fail, never publish an ad-hoc or differently signed app (Task 2 manual check 4).

---

### Task 1: Debug builds get their own identity

**Files:**
- Modify: `App/project.yml` (target `Dustling` settings)
- Modify: `App/README.md` (one paragraph: Debug builds are "Dustling Dev", `app.dustling.Dustling.debug`, and need their own Full Disk Access)

- [ ] **Step 1:** In `App/project.yml`, under `targets.Dustling.settings`, keep `base` as is and add `configs.Debug` with `PRODUCT_BUNDLE_IDENTIFIER: app.dustling.Dustling.debug` and `INFOPLIST_KEY_CFBundleDisplayName: "Dustling Dev"`. Release keeps `app.dustling.Dustling` / `Dustling`. Do not change `PRODUCT_NAME` (the executable must stay `Dustling`; `WriterProcesses.names` relies on it).
- [ ] **Step 2:** Run `cd App && xcodegen generate --quiet && xcodebuild -project Dustling.xcodeproj -scheme Dustling -configuration Debug -derivedDataPath ../.build/task1 build -quiet` then `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleDisplayName' -c 'Print :CFBundleExecutable' ../.build/task1/Build/Products/Debug/Dustling.app/Contents/Info.plist`. Expected: `app.dustling.Dustling.debug`, `Dustling Dev`, `Dustling`.
- [ ] **Step 3:** Confirm `scripts/qa-screens.sh` still overrides the bundle ID to `app.dustling.Dustling.qa` (it passes it on the command line) and still works: `scripts/qa-screens.sh` ends with "No problems found".
- [ ] **Step 4:** Commit: `git commit -m "build: Debug builds are Dustling Dev with their own bundle ID"`.

### Task 2: Release builds signed with one certificate

**Files:**
- Create: `scripts/make-signing-certificate.sh` (one-time: makes the key and certificate)
- Create: `App/Signing/README.md` (what the certificate is for; how to rotate; that rotating costs every user one re-grant)
- Modify: `scripts/build-dmg.sh`
- Modify: `.github/workflows/release.yml`
- Modify: `docs/RELEASING.md` ("Signing" section), `docs/INSTALL.md` (one sentence: Full Disk Access stays on through updates from 0.x.y on)

**Interfaces:**
- Produces: `App/Signing/release-certificate.sha1` (one line, 40 lowercase hex digits, the certificate's SHA-1) and `App/Signing/release-certificate.pem` (public certificate). Created by running the script once, after the maintainer's OK; until then the files don't exist.
- `scripts/build-dmg.sh` new inputs: `--require-signing`; env `DUSTLING_SIGNING_P12_BASE64` (base64 PKCS#12) or `DUSTLING_SIGNING_P12` (path), and `DUSTLING_SIGNING_P12_PASSWORD`; env `DUSTLING_SIGNING_EXPECTED_SHA1` overrides the pinned file (tests only).

- [ ] **Step 1: `scripts/make-signing-certificate.sh <out-dir>`.** With openssl: RSA 3072 key, self-signed X.509, `CN = Dustling Release Signing`, validity 7300 days, extensions `basicConstraints=critical,CA:false`, `keyUsage=critical,digitalSignature`, `extendedKeyUsage=critical,codeSigning`. Writes `<out-dir>/dustling-signing.p12` (password from env `DUSTLING_SIGNING_P12_PASSWORD`, refuses to run without it), writes the public PEM to `App/Signing/release-certificate.pem` and the lowercase SHA-1 of the DER certificate to `App/Signing/release-certificate.sha1`, and prints the two `gh secret set` commands to run. Refuses to overwrite existing `App/Signing/release-certificate.*` unless `--rotate` is given (and then prints that every user must turn Full Disk Access on again once). Never writes the key inside the repo.
- [ ] **Step 2: Signing in `build-dmg.sh`.** After the "Checking the app" step and before packing: if a P12 is provided, create a temporary keychain under `$STAGE`-like temp dir (random password, `security create-keychain`, `set-keychain-settings` without timeout, `unlock-keychain`, `import -T /usr/bin/codesign`, `set-key-partition-list -S apple-tool:,apple:,codesign:`), find the identity's SHA-1 with `security find-identity -p codesigning <kc>` (not `-v`: a self-signed identity is listed as not trusted), check it equals the pinned SHA-1 (fail: "the signing certificate isn't Dustling's release certificate; signing with another one would turn Full Disk Access off for everyone"), then `codesign --force --sign <sha1> --keychain <kc> --options runtime --timestamp=none "$APP"` (no entitlements: drops `get-task-allow`). Verify: `codesign --verify --deep --strict "$APP"` and `codesign -d -r- "$APP"` prints exactly `designated => identifier "app.dustling.Dustling" and certificate leaf = H"<pinned sha1>"`. Delete the keychain in the existing `cleanup` trap. Without a P12: ad hoc as today, and `--require-signing` makes that an error ("release builds must be signed with Dustling's certificate; see docs/RELEASING.md"). Print which signature the app got in the "Checking the disk image" step.
- [ ] **Step 3: Workflow.** In `release.yml`, the "Build the disk image" step gets `DUSTLING_SIGNING_P12_BASE64: ${{ secrets.DUSTLING_SIGNING_P12_BASE64 }}` and `DUSTLING_SIGNING_P12_PASSWORD: ${{ secrets.DUSTLING_SIGNING_P12_PASSWORD }}` only when the ref is a tag (use an `if` on two separate steps, or pass them and add `--require-signing` only for tags). Pull request builds stay ad hoc and never receive the secrets.
- [ ] **Step 4: Manual checks (record the output in the task report).** With a throwaway certificate made by the script into a temp dir and `DUSTLING_SIGNING_EXPECTED_SHA1` set to its SHA-1:
  1. `scripts/build-dmg.sh` signs; `codesign -d -r-` shows the leaf requirement.
  2. Build at two different commits (or touch a source file between builds); `codesign -v -R='<DR of build 1>' <build 2>.app` exits 0.
  3. `scripts/build-dmg.sh --require-signing` without the env fails with the message above.
  4. With a second throwaway certificate but the first one's SHA-1 expected: fails before signing.
  5. The disk image still verifies (`hdiutil verify`, `codesign --verify --deep --strict` on the mounted app).
- [ ] **Step 5:** Docs as listed above. Commit: `git commit -m "build: sign releases with Dustling's own certificate so Full Disk Access survives updates"`.

### Task 3: Know which copy had Full Disk Access, and say so

**Files:**
- Create: `Sources/DustlingCore/Health/CodeIdentity.swift`
- Modify: `Sources/DustlingAppModel/Health/Repair.swift` (`FullDiskAccessMemory`, `RepairCase` copy)
- Modify: `App/Dustling/AppModels.swift` (construct the memory with the current requirement), `App/Dustling/Health/BlockerSheet.swift`, `App/Dustling/Health/HealthLightsPopover.swift` (use the cause-aware copy), `App/Dustling/Onboarding/FullDiskAccessStep.swift` (stale-entry hint and "this copy" line)
- Test: `Tests/DustlingAppModelTests/RepairTests.swift`, `Tests/DustlingCoreTests/HealthCheckTests.swift` (or a new `CodeIdentityTests.swift`)

**Interfaces:**
- Produces (Core): `public enum CodeIdentity { public static func currentDesignatedRequirement() -> String?; public static func runningLocation(bundleURL: URL) -> RunningLocation }` and `public enum RunningLocation: Equatable, Sendable { case applications, translocated, diskImage, elsewhere }` (`/AppTranslocation/` anywhere in the path → `.translocated`; path under `/Volumes/` → `.diskImage`; parent is `/Applications` or `~/Applications` → `.applications`; else `.elsewhere`).
- Produces (AppModel): `public enum FullDiskAccessLoss: Equatable, Sendable { case newCopy, turnedOff, unknown }`; `FullDiskAccessMemory.init(defaults: UserDefaults = .standard, currentRequirement: String? = CodeIdentity.currentDesignatedRequirement())`; `public static let requirementKey = "fullDiskAccessGrantedRequirement"`; `public func lossCause(_ status: FullDiskAccessStatus) -> FullDiskAccessLoss?` (nil unless `isLost`); `isLost` keeps its meaning; `observe(.granted)` stores `currentRequirement` (when non-nil) under `requirementKey`; `acknowledgeLoss()` also removes `requirementKey`; `useSample(wasGranted:)` unchanged. `public static func fullDiskAccessLostCopy(_ cause: FullDiskAccessLoss) -> RepairCase.Copy`; `RepairCase.fullDiskAccessLost.copy` returns `fullDiskAccessLostCopy(.unknown)`.

- [ ] **Step 1: Failing tests** in `RepairTests.swift`:
  - `lossCauseIsNewCopyWhenRequirementDiffers`: memory A (`currentRequirement: "req-A"`) observes `.granted`; memory B on the same defaults with `"req-B"`: `lossCause(.denied) == .newCopy`.
  - `lossCauseIsTurnedOffForSameRequirement`: same requirement → `.turnedOff`.
  - `legacyFlagWithoutRequirementIsUnknownCause`: defaults with only `fullDiskAccessWasGranted = true` → `.unknown`.
  - `noCauseWhenNeverGrantedOrGranted`: fresh defaults → `lossCause(.denied) == nil`; after observe → `lossCause(.granted) == nil`, `lossCause(.unknown) == nil`.
  - `nilRequirementStoresNothing`: memory with `currentRequirement: nil` observes `.granted`: `requirementKey` absent, later loss is `.unknown`.
  - `acknowledgeClearsRequirement`.
  - `lostCopyPerCause`: titles exactly `"Turn Full Disk Access on for this copy"` (`.newCopy`), `"Full Disk Access was turned off"` (`.turnedOff`, `.unknown`); fix is `"Open System Settings"` for all; `.newCopy` and `.unknown` why-texts contain `"click −"`.
  - Core: `runningLocationClassifiesPaths` for the four cases (`/private/var/folders/x/AppTranslocation/ABC/d/Dustling.app`, `/Volumes/Dustling/Dustling.app`, `/Applications/Dustling.app`, `/Users/me/Downloads/Dustling.app`); `currentDesignatedRequirementIsReadableInTests` (`swift test` runs a signed `xctest`/`swiftpm-testing-helper`: expect non-nil and non-empty, or skip with a comment if the test host is unsigned).
- [ ] **Step 2:** Run `swift test --filter RepairTests` → fails (missing symbols).
- [ ] **Step 3: Implement.** `currentDesignatedRequirement()`: `SecCodeCopySelf([], &code)`, `SecCodeCopyDesignatedRequirement(code, [], &req)`, `SecRequirementCopyString(req, [], &string)`; nil on any failure. Exact copy:
  - `.newCopy` why: `"macOS gives this permission to one exact copy of an app. This Dustling is a different copy (an update, or a second copy on this Mac), so macOS asks again. If System Settings already shows Dustling switched on, that's the other copy: select Dustling, click −, then drag this Dustling into the list."`
  - `.turnedOff` why: `"Dustling is switched off under Full Disk Access in System Settings. Dustling noticed by trying a real read, so nothing was scanned with missing folders."`
  - `.unknown` why: `"Full Disk Access is off for this copy of Dustling. If System Settings shows Dustling switched on, macOS is holding it for another copy: select Dustling, click −, then drag this Dustling into the list."`
- [ ] **Step 4: Views.** `AppModels` exposes `var fullDiskAccessLoss: FullDiskAccessLoss? { accessMemory.lossCause(health.fullDiskAccess) }`. `BlockerSheet` and the health popover line use `RepairCase.fullDiskAccessLostCopy(models.fullDiskAccessLoss ?? .unknown)` for `.fullDiskAccessLost`. In `FullDiskAccessStep`, while not granted: after the step has been visible for 8 seconds without access (a `.task` with `Task.sleep`, reset when access changes), show a muted line under the status line: `"Already switched on in System Settings? macOS may be holding it for another copy of Dustling. Select Dustling, click −, then drag this one into the list."`; and when `runningLocation` is `.translocated` or `.diskImage`, show (always, not delayed) `"You opened Dustling from the disk image or Downloads. Move it to Applications and open it from there first, so the permission goes to the copy you keep."`
- [ ] **Step 5:** `swift test` passes; build the app (Debug) and check with `-DustlingScreen`/fixtures that the blocker sheet shows the new copy without clipping (`scripts/qa-screens.sh` "No problems found").
- [ ] **Step 6:** CHANGELOG `### Fixed` line. Commit: `git commit -m "fix(app): say when Full Disk Access belongs to another copy of Dustling"`.

### Task 4: Empty Trash finishes what it can and says what it can't

**Files:**
- Create: `Sources/DustlingCore/Cleanup/TrashUnlocker.swift`
- Modify: `Sources/DustlingCore/Cleanup/TrashInspector.swift` (`emptyTrash()`)
- Modify: `Sources/DustlingAppModel/Trash/TrashModel.swift` (problems summary), `App/Dustling/Trash/EmptyTrashSheet.swift` (stay open and report)
- Test: `Tests/DustlingCoreTests/TrashUnlockerTests.swift`, `Tests/DustlingCoreTests/TrashInspectorTests.swift`, `Tests/DustlingAppModelTests/TrashModelTests.swift`

**Interfaces:**
- Produces (Core): `public enum TrashUnlocker { public static func unlockOwnItems(in root: URL, userID: uid_t) -> Int; public static func blocker(of root: URL, userID: uid_t) -> TrashBlocker? }` and `public enum TrashBlocker: Equatable, Sendable { case otherOwner(count: Int), protectedByMacOS }`. `unlockOwnItems` walks `root` without following symlinks (`fts_open` with `FTS_PHYSICAL | FTS_NOCHDIR`), and for every entry owned by `userID` clears `UF_IMMUTABLE | UF_APPEND` with `lchflags` when set, and adds `S_IWUSR | S_IXUSR` to directories lacking them with `chmod` on the directory (never on a symlink); returns how many entries it changed. `blocker` returns `.otherOwner(count:)` with the number of entries not owned by `userID` whose parent directory the user can't write (`access(parent, W_OK) == EACCES`), `.protectedByMacOS` when a remaining entry fails with EPERM although its owner is the user, nil otherwise.
- `TrashInspector.emptyTrash()` per child: `removeItem`; on failure `unlockOwnItems` then `removeItem` again; on second failure: `.otherOwner` → `.needsAdmin`; `.protectedByMacOS` → `.failed(reason: "protected by macOS")`; nil → `.failed(reason: error.localizedDescription)`.
- Produces (AppModel): `public struct EmptyTrashProblems: Equatable, Sendable { public let needsAdmin: Int; public let protected: Int; public let failed: Int; public static func of(_ record: RunRecord) -> EmptyTrashProblems?; public var message: String }` (nil when nothing was left).

- [ ] **Step 1: Failing core tests** (in `TestSandbox`; an "other owner" can't be created without root, so `blocker` takes its facts through an internal test seam `blocker(of:userID:owner:)` where `owner` is a `(URL) -> uid_t`):
  - `unlockClearsUserImmutableAndReadOnlyDirectories`: a folder `locked/` with mode 0555 containing `a.bin` with `uchg` set (`chflags uchg`): `removeItem` fails, `unlockOwnItems` returns ≥ 2, `removeItem` then succeeds.
  - `unlockNeverFollowsSymlinks`: `home/.Trash/link` → symlink to `outside/` (mode 0555, file with `uchg`): after `unlockOwnItems(in: link)` the target's mode is still 0555 and the flag is still set.
  - `emptyTrashDeletesLockedOwnItems`: `emptyTrash()` on a Trash with the locked folder above records `.deleted` and leaves the Trash empty.
  - `mixedOwnershipReportsNeedsAdmin`: seam reports two entries owned by uid 503 in a read-only folder → `.otherOwner(count: 2)`, and `emptyTrash()` (through an inspector seam that injects the blocker) records `.needsAdmin` for that child while deleting its other siblings.
  - Restore modes in `defer` so the sandbox can be cleaned up.
- [ ] **Step 2:** `swift test --filter "TrashUnlocker|TrashInspector"` fails.
- [ ] **Step 3:** Implement as in Interfaces.
- [ ] **Step 4: App model.** `EmptyTrashProblems.message` exact copy, joined with a space, parts only when non-zero: needs admin → `"N item(s) belong to another account on this Mac, usually because an installer put them there. Open the Trash in Finder and empty it there: Finder asks for your password."`; protected → `"N item(s) are protected by macOS and can't be deleted."`; failed → `"N item(s) couldn't be deleted. The log has the reason for each."`. Tests in `TrashModelTests` for one-of-each and the singular/plural wording.
- [ ] **Step 5: Sheet.** `EmptyTrashSheet` on `.emptied(record)`: if `EmptyTrashProblems.of(record)` is nil, dismiss as today; otherwise stay open, replace the confirmation text with the deleted total (`"Deleted X."`) and the problems message in the warning style, hide "Empty Trash", show `"Open Trash in Finder"` (opens `~/.Trash` with `NSWorkspace.shared.open`) when `needsAdmin > 0`, and `"Done"` as the default button.
- [ ] **Step 6:** `swift test`; `scripts/qa-screens.sh` (add a fixture state for the sheet's problem state if the screen check has fixtures for this sheet). CHANGELOG `### Fixed` lines. Commit: `git commit -m "fix: Empty Trash deletes your locked items and explains what it can't delete"`.

### Task 5: Say "protected by macOS" when a move is refused for that reason

**Files:**
- Modify: `Sources/DustlingCore/Cleanup/TrashMover.swift`
- Modify: `Sources/DustlingAppModel/Health/Repair.swift` (`LastRunReview.problems`: protected items have no Retry fix)
- Test: `Tests/DustlingCoreTests/TrashMoverTests.swift`, `Tests/DustlingAppModelTests/RepairTests.swift`

**Interfaces:**
- Produces: `public static let protectedReason = "protected by macOS"` on `TrashMover`. When `backend.trash(url)` throws and the error (or its `NSUnderlyingErrorKey`, recursively) is POSIX `EPERM`, the outcome is `.failed(reason: TrashMover.protectedReason)`; other errors keep `localizedDescription`.

- [ ] **Step 1: Failing tests:** `trashRefusedWithEPERMIsProtected` (a backend stub throwing `CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])` → `.failed(reason: "protected by macOS")`), `trashRefusedWithEACCESKeepsDescription`, and in `RepairTests` `protectedItemsHaveNoRetry` (a junk-clean run with one `.failed(reason: "protected by macOS")` entry lists the problem with reason `"Protected by macOS"` and `fix == nil`, and `retryableCount == 0`).
- [ ] **Step 2:** Run, see them fail. **Step 3:** Implement. **Step 4:** `swift test` passes. **Step 5:** CHANGELOG line; commit `git commit -m "fix: say when macOS protects an item instead of a vague permission error"`.

### Task 6: Run admin commands behind the macOS password box

Kaan approved (2026-11-12): items that belong to the system are removed by asking for the Mac password with the standard macOS box, once per cleanup, uninstall, Empty Trash or Put back.

**Files:**
- Create: `Sources/DustlingCore/Admin/AdminShell.swift`, `Sources/DustlingCore/Admin/AdminScript.swift`, `Sources/DustlingCore/Admin/AdminMover.swift`
- Test: `Tests/DustlingCoreTests/AdminScriptTests.swift`, `Tests/DustlingCoreTests/AdminMoverTests.swift`, `Tests/DustlingCoreTests/Support/UserShell.swift` (a fake `AdminShell` that runs the script with `/bin/sh -c` as the current user, and one that returns `.cancelled`)

**Interfaces:**
- `public protocol AdminShell: Sendable { func run(script: String, prompt: String) -> AdminShellResult }`
- `public enum AdminShellResult: Equatable, Sendable { case finished(output: String), cancelled, failed(reason: String) }`
- `public struct OsascriptAdminShell: AdminShell` — runs `/usr/bin/osascript -e <applescript>` as a child process (never `NSAppleScript`, which must run on the main thread and would freeze the window while files move), where the AppleScript is `do shell script "<script>" with prompt "<prompt>" with administrator privileges without altering line endings` with `\` and `"` escaped. osascript exit status non-zero with `-128` or `User canceled` in stderr → `.cancelled`; other non-zero → `.failed(reason:)` with stderr trimmed. Internal `init(privileged: Bool)` (default true) so one test can run it without the password box.
- `public enum AdminOp: Equatable, Sendable { case move(from: URL, to: URL, bootOutDaemon: Bool), delete(URL) }`, `public struct AdminStep: Equatable, Sendable { public let op: AdminOp; public let dependsOn: Int? }` (index of an earlier step that must have succeeded), `public enum AdminStepResult: Equatable, Sendable { case done, notDone(reason: String), cancelled }`.
- `public enum AdminScript { public static func make(_ steps: [AdminStep]) -> String; public static func parse(_ output: String, count: Int) -> [AdminStepResult] }`. The script is POSIX sh, starts with `set +e` and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, uses absolute tool paths, single-quotes every path (`'` → `'\''`), passes `--` before paths, and prints exactly one line per step: `R<TAB><index><TAB>ok|gone|skip|exists|err`. Move: `skip` when its `dependsOn` step didn't succeed; `gone` when the source doesn't exist (`[ -e ] || [ -L ]` false); `exists` when the destination exists; otherwise (if `bootOutDaemon`, first `/bin/launchctl bootout system <source> >/dev/null 2>&1`, result ignored) `/bin/mv -n -- <src> <dst>`, and `ok` only if afterwards the source is gone and the destination exists, else `err`. Delete: `/bin/rm -rf -- <path>`, `ok` iff the path is gone after. `parse` maps ok → `.done`; gone → `.notDone(reason: "already gone")`; skip → `.notDone(reason: "kept because the app itself was not removed")`; exists → `.notDone(reason: "something with the same name is already there")`; err → `.notDone(reason: "macOS refused, even with your password")`; a missing line → `.notDone(reason: "no result")`.
- `public struct AdminMover: Sendable { public init(shell: AdminShell, environment: SystemEnvironment); public func trashDestination(for url: URL, taken: Set<String> = []) -> URL?; public func perform(_ steps: [AdminStep], prompt: String) -> [AdminStepResult] }`. `trashDestination` returns a path in `environment.userTrash` with the item's name, or "name 2", "name 3"… (before the extension for files: "Report 2.pdf") that doesn't exist (lstat) and isn't in `taken`; nil when the item is on a different volume (`st_dev`) than `environment.userTrash`. `perform` with no steps returns `[]` without calling the shell; `.cancelled` → every step `.cancelled`; `.failed(reason)` → every step `.notDone(reason:)`.
- Prompt strings (exact, used by later tasks): `AdminMover.movePrompt(count:)` → `"Dustling needs your password to move 1 item that belongs to the system to the Trash."` / `"…to move N items that belong to the system to the Trash."`; `deletePrompt(count:)` → `"Dustling needs your password to delete 1 item in the Trash that belongs to the system."` / `"…to delete N items in the Trash that belong to the system."`; `restorePrompt(count:)` → `"Dustling needs your password to put back 1 item into a system folder."` / `"…to put back N items into system folders."`

- [ ] **Step 1: Failing tests** (`AdminScriptTests`, running the script for real through the user-level fake shell inside a `TestSandbox`; NEVER construct `OsascriptAdminShell(privileged: true)` in a test, it would put a password box on the screen):
  - `moveMovesAndReportsOk`, `moveOfMissingSourceIsGone`, `moveNeverOverwrites` (destination exists → `exists`, source untouched), `dependentStepIsSkippedWhenItsHeadFails`, `deleteRemovesTree`, `parseMissingLinesAsNoResult`.
  - `quotingSurvivesHostileNames`: names `it's "q" $HOME \`echo x\` ;rm -rf ~ & é.app` and one with a newline move correctly and nothing else in the sandbox changes.
  - `AdminMoverTests`: `trashDestinationAddsNumberBeforeExtension`, `trashDestinationSkipsTaken`, `cancelledShellCancelsEveryStep`, `emptyStepsNeverCallShell` (a shell that records calls).
  - `osascriptWithoutPrivilegesRunsScript`: `OsascriptAdminShell(privileged: false).run(script: "echo 'a\"b'", prompt: "x")` returns `.finished(output: "a\"b\n")`.
- [ ] **Step 2:** `swift test --filter "AdminScript|AdminMover"` fails. **Step 3:** Implement. **Step 4:** Pass. **Step 5:** Commit `feat: run admin file moves behind the macOS password box`.

### Task 7: Cleanups, uninstalls, Empty Trash and Put back use the password box

**Files:**
- Modify: `Sources/DustlingCore/Cleanup/CleanupRunner.swift`, `Sources/DustlingCore/Uninstaller/Uninstaller.swift`, `Sources/DustlingCore/Cleanup/TrashInspector.swift`, `Sources/DustlingCore/History/RunJournal.swift`
- Test: `CleanupRunnerTests.swift`, `UninstallerTests.swift`, `TrashInspectorTests.swift`, `RunJournalTests.swift`

**Interfaces:**
- Consumes: Task 6's `AdminMover`, `AdminStep`, `AdminStepResult`, prompts; Task 4's `TrashBlocker`.
- `CleanupRunner.init(mover:journal:logger:sizer:admin: AdminMover? = nil)` (the CLI passes nil and behaves as today). In `runBlocking`, an item whose attempt is `.needsAdmin`, when `admin != nil` and `trashDestination` is non-nil, is held: not added or reported yet. After the loop (if not cancelled; held items of a stopped run become `.skipped(reason: "cleanup stopped")`), one `perform` with all held moves (`bootOutDaemon` true when the item's parent is `<systemLibrary>/LaunchDaemons`) and `movePrompt`; then each held item is added and `onItem` fires exactly once: `.done` → `.movedToTrash(trashedPath:)` with `trashedIdentity`; `.cancelled` → `.needsAdmin`; `.notDone(reason)` → `.failed(reason:)`.
- `Uninstaller`: per-app behavior unchanged. New `public func moveSystemItems(_ records: [RunRecord], jobs: [UninstallJob]) async -> [RunRecord]` where `public struct UninstallJob: Sendable { public let app: InstalledApp; public let leftovers: [Leftover] }`. For each record (matched to its job by the app path in entry 0): if the app entry is `.needsAdmin`, steps = app move, then every kept leftover with `requiresAdmin` as dependent steps; if the app moved, every `.needsAdmin` leftover entry is a step. One `perform` for all records with `movePrompt`. Afterwards, for every app that the password step moved, its kept non-admin leftovers are moved the normal way (launch agents booted out first, exactly as `uninstallBlocking` does). Entries are replaced in place, `restorable` recomputed, each changed record saved to the journal and logged. With `admin == nil` (runner has none) it returns the records unchanged.
- `TrashInspector.emptyTrash()` uses the runner-independent `admin: AdminMover?` given to its init (default nil): children recorded `.needsAdmin` (Task 4) are deleted in one `perform` with `deletePrompt` — only paths whose parent is a Trash location `discover()` returned; `.done` → `.deleted`; `.cancelled` → `.needsAdmin`; `.notDone(r)` → `.failed(reason: r)`.
- `RunJournal.restore(runID:paths:admin: AdminMover? = nil)`: entries whose move back failed with a permission error (the existing `isPermissionError`) while the destination folder is not writable, or the item is a directory the user can't write, are collected and, with `admin`, moved back in one `perform` (`move(from: trashed, to: original, bootOutDaemon: false)`) with `restorePrompt`; `.done` → `.restored`; `.cancelled` → `.failed(reason: "Put back needs your password")`; `.notDone(r)` → `.failed(reason: r)`.

- [ ] **Step 1: Failing tests** with a fake `AdminShell` that runs the script as the user (so "admin" items are simulated by a `TrashMover` permission seam or a backend that reports `.needsAdmin` for chosen paths; check how `TrashMoverTests` fakes permissions and reuse it):
  - `runnerMovesNeedsAdminItemsWithOnePrompt` (two held items, one shell call, both `.movedToTrash`, each `onItem` once, journal and log show the final outcomes).
  - `runnerKeepsNeedsAdminWhenPasswordCancelled`, `runnerWithoutAdminIsUnchanged`, `stoppedRunNeverAsksForPassword`.
  - `uninstallerMovesSystemAppAndItsLeftoversAfterPassword` (app needs admin, one admin leftover and one user leftover: one shell call; app and admin leftover moved by the script, user leftover moved afterwards; record restorable).
  - `uninstallerKeepsLeftoversWhenSystemAppStays` (shell result `.cancelled` → app `.needsAdmin`, leftovers still kept).
  - `uninstallerBatchesSeveralAppsIntoOnePrompt` (two records → one shell call).
  - `emptyTrashDeletesSystemItemsWithPassword`, `emptyTrashNeverDeletesOutsideTrashWithPassword` (a needs-admin entry whose parent isn't a Trash location is not in the script).
  - `restoreUsesPasswordForSystemFolders`.
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit `feat: move, delete and put back system items with your password`.

### Task 8: The app asks once and says so

**Files:**
- Modify: `App/Dustling/AppModels.swift` (build one `AdminMover(shell: OsascriptAdminShell(), environment:)` and pass it to the runner, the uninstaller's runner, the Trash inspector and every `journal.restore` call; in DEBUG, when any screenshot fixture, `-DustlingScreen`, `-DustlingLayoutCheck` or `DustlingQAAssumeFullDiskAccess` is active, pass nil so the QA copy can never raise a password box)
- Modify: `Sources/DustlingAppModel/Uninstaller/UninstallerModel.swift` (after the loop in `uninstallSelected`, call `uninstaller.moveSystemItems(records, jobs:)` once, update `progress` rows and `result` with the returned records without double-counting `itemsDone`, and drop apps that moved from the list), `JunkScanModel`, `HistoryModel`, `UninstallerModel.putBack` (pass `admin` to `journal.restore`), `Repair.swift` (`LastRunReview`: `.needsAdmin` problems get reason `"Needs your Mac password"` and fix `.retry`; `retryPlan` includes `.needsAdmin` entries of junk cleanups and no longer filters out `requiresAdmin` categories)
- Modify copy (exact): every `"Needs the cleanup helper (coming in a later version)"` / `"needs the cleanup helper"` used for files in Junk, Uninstaller, History, Diagnostics and `Presentation.swift` becomes `"Needs your Mac password"` / `"needs your Mac password"`; the Uninstaller confirmation note becomes `"1 item belongs to the system. Dustling will ask for your Mac password to move it."` / `"N items belong to the system. Dustling will ask for your Mac password to move them."`. Startup items and the helper health light keep their helper wording (launch daemon switching is still the helper's job).
- Test: the matching AppModel tests (`UninstallerModelTests` `systemItemsAskOnceAfterTheLoop`, `RepairTests` `needsAdminProblemsCanBeRetried`, screen-copy tests that pin the old strings).

- [ ] Steps: failing tests, implement, `swift test`, `scripts/qa-screens.sh` "No problems found", CHANGELOG `### Added` line ("Apps and files that belong to the system … Dustling asks for your Mac password once …"), commit `feat(app): ask for the Mac password once to remove what belongs to the system`.

### Task 9: Release

- [ ] Version 0.2.0 (new feature). Bump `MARKETING_VERSION`, move `[Unreleased]` to `## [0.2.0] - <date>`, update links (docs/RELEASING.md step 1). The changelog's top paragraph says Full Disk Access must be turned on once more after this update and then stays on.
- [ ] Run the QA pass (`swift test`, `scripts/qa-screens.sh`, the by-hand list as far as it can be done on this Mac) and record it in the PR.
- [ ] Before tagging: the signing secrets exist (`gh secret list` shows both names) and `App/Signing/release-certificate.sha1` is committed.
