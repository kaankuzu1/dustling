# Releasing Dustling

Dustling is released in numbered versions. Each version is a git tag (`v0.2.0`), a GitHub release with `Dustling.dmg`, and a section in [CHANGELOG.md](../CHANGELOG.md).

## Versions

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While Dustling is at 0.x:

| Change | Example | Next version |
| --- | --- | --- |
| Fixes only | A button that can't be reached, a wrong size | 0.1.0 → **0.1.1** |
| New features or changed behavior | The admin helper, a new cleaning category | 0.1.1 → **0.2.0** |
| Ready to call stable | Signed, notarized, everything planned for 1.0 | 0.x → **1.0.0** |

A test build for others to try gets a suffix, like `v0.2.0-beta.1`. It is released as a pre-release, which the "latest" download link skips.

## While working

Every pull request that changes what people see or what Dustling does adds a line to the `## [Unreleased]` section of CHANGELOG.md, under one of these headings: **Added**, **Changed**, **Fixed**, **Removed**, **Security**. Write it for people who use the app, not for developers. Internal changes (tests, refactors, CI) don't need a line.

## Releasing a version

1. **Prepare the release in a pull request.**
   - In `App/project.yml`, set `MARKETING_VERSION` to the new version, for example `"0.2.0"`. This is the only place the app's version lives. The build number is set automatically from the number of commits.
   - In `CHANGELOG.md`, rename `## [Unreleased]` to `## [0.2.0] - YYYY-MM-DD` with today's date, and add a new empty `## [Unreleased]` above it.
   - At the bottom of `CHANGELOG.md`, update the links:
     ```
     [Unreleased]: https://github.com/kaankuzu1/dustling/compare/v0.2.0...HEAD
     [0.2.0]: https://github.com/kaankuzu1/dustling/compare/v0.1.0...v0.2.0
     ```
   - Run the [QA pass](#qa-pass) on this branch and paste its checklist, ticked, into the pull request.
   - Merge the pull request into `main`.

2. **Tag the merge commit and push the tag.**
   ```bash
   git switch main && git pull
   git tag -a v0.2.0 -m "Dustling 0.2.0"
   git push origin v0.2.0
   ```

3. **Let the workflow build it.** The tag starts the [Release workflow](../.github/workflows/release.yml). It runs the tests, checks that the tag matches `MARKETING_VERSION` and that CHANGELOG.md has a section for it, builds `Dustling.dmg`, and creates a **draft** release with the changelog section and install steps as its notes. Nothing is public yet.

4. **Check the draft.** Download `Dustling.dmg` from the draft release and go through the [install checks](#install-and-update) with it. Read the notes.

5. **Publish.** On the draft release, click **Edit**, then **Publish release**. From then on, `https://github.com/kaankuzu1/dustling/releases/latest/download/Dustling.dmg` serves the new version, and so does the website's Download button.

6. **Update the website.** In the `dustling-website` repository, set `VERSION` in `src/site.ts` to the new version and merge.

If something is wrong after step 2, delete the draft release and the tag (`git push --delete origin v0.2.0` and `git tag -d v0.2.0`), fix it on `main`, and tag again.

## QA pass

Every release gets the same checks, so small problems are found before people find them. Do them on the release pull request's branch, and the install checks again with the draft release's disk image.

### Automated

```bash
swift test
scripts/qa-screens.sh
```

`scripts/qa-screens.sh` opens a separate copy of Dustling (its own settings, sample data, sample home folders; it never touches your files or your Dustling) in about 40 screen states: every fixture state, the empty states, many oddly named items and no Full Disk Access. For each one, in light and dark, at the smallest window, the default and a large one, it saves a picture of every window and sheet and checks every control: it must have a name VoiceOver can read, and it must not be cut off by the edge of its window or sheet. It ends with "No problems found" or a list of problems, and writes `dist/qa/<time>/index.html`.

Then open `index.html` and look through every picture for what a check can't see: text that is cut off or overlaps, loading placeholders that don't line up with what replaces them, icons that disappear in light or dark, empty states that look broken. Without Screen Recording or Accessibility permission it still works: it only reads its own windows.

### By hand

Copy this into the release pull request and tick each line. Use a build of the branch (`App/README.md`) for all but the install checks.

**Install and update**

- [ ] First install: on a Mac user account that never ran Dustling, open the disk image. Its window shows the background, Dustling and the Applications folder, none cut off by the title bar.
- [ ] Drag Dustling to Applications and open it: macOS asks once to confirm ([INSTALL.md](INSTALL.md)), then the setup opens over the main window. The sidebar shows "Startup items" in full.
- [ ] Update: drag the new version over the old one while the old one is closed, then while it is open. Replacing works, and the new version opens.
- [ ] After the update from a signed release, Full Disk Access is still on and Dustling doesn't ask for it again.

**Permissions**

- [ ] Full Disk Access off: Home shows limited mode and which places it couldn't read; the Uninstaller waits for access; nothing shows 0 bytes for a place it couldn't read.
- [ ] Turn Full Disk Access on while Dustling is open: it notices without a restart.

**Every screen**

- [ ] Home, Junk scan, Uninstaller, Startup items, History, Dustling health and each Settings section open, in light and dark, and switching the appearance while open redraws everything.
- [ ] At the smallest window size and in full screen, nothing is cut off and every button can be reached.
- [ ] With nothing to clean, no apps selected and an empty History, the screens say so plainly.

**Doing and undoing**

- [ ] Stop a junk scan halfway: it stops, and what was found so far stays.
- [ ] Clean some junk, then Put everything back from the summary and one item from History.
- [ ] Uninstall a test app, Stop an uninstall of several apps halfway, and put an app back.
- [ ] Turn a startup item off and on again.
- [ ] Cancel and Escape close every sheet without doing anything; Empty Trash always asks first.

**Quit**

- [ ] Quit (⌘Q) during a scan, during a cleanup, during an uninstall and with each sheet open: it quits after stopping cleanly. Reopen: History shows the interrupted run as it ended.

**Keyboard, VoiceOver and motion**

- [ ] Keyboard only: Tab reaches every button; arrow keys move in the sidebar and the lists; Return and Escape work in every sheet; ⌘, opens Settings.
- [ ] VoiceOver (⌘F5): the sidebar, a junk category, an app row while uninstalling, a sheet and a History log line each read something useful.
- [ ] Reduce Motion on (System Settings > Accessibility > Display): scanning, cleaning and the summary appear without movement.

Anything found goes into a pull request with a line under `## [Unreleased]`, and the QA pass runs again on what changed.

## Building the disk image yourself

```bash
scripts/build-dmg.sh
```

It needs Xcode 26 or later and XcodeGen (`brew install xcodegen`), and writes `dist/Dustling.dmg` and `dist/Dustling.dmg.sha256`. The app is a universal binary (Apple silicon and Intel). Without the signing key it gets an ad hoc signature; see [Signing](#signing). `scripts/release-notes.sh 0.2.0` prints the notes a release would get.

The install window is laid out by [`App/DMG/dmg-settings.py`](../App/DMG/dmg-settings.py) (icon positions, window size) over the picture in [`App/DMG/background.html`](../App/DMG/background.html). After changing the HTML, run `scripts/make-dmg-background.sh` (it needs Google Chrome) and commit the two PNGs it writes. Finder always shows a window with a background picture in light mode, so keep the picture light.

Every pull request that touches the app, the package or these scripts also runs the Release workflow without publishing anything, so a broken build shows up before it reaches a tag. The disk image it builds is attached to the workflow run for 14 days.

## Signing

Releases are signed with one self-signed certificate, `Dustling Release Signing`, so that Full Disk Access stays on through updates: macOS keeps that permission by the app's signature, and a certificate that never changes gives every version the same one. It is not an Apple certificate, so macOS still asks people to confirm the first open ([INSTALL.md](INSTALL.md)). [App/Signing/README.md](../App/Signing/README.md) explains the certificate and what rotating it costs.

- **The key** is in the GitHub secrets `DUSTLING_SIGNING_P12_BASE64` and `DUSTLING_SIGNING_P12_PASSWORD`, and in the maintainer's `dustling-signing.p12`. `scripts/make-signing-certificate.sh` makes it once and prints the `gh secret set` commands.
- **Tag builds** get the secrets and run `scripts/build-dmg.sh --require-signing`, which fails if the app would be ad hoc, or if the key isn't the certificate pinned in `App/Signing/release-certificate.sha1`. Pull request and manual builds never receive the secrets and stay ad hoc.
- **To sign locally**, set `DUSTLING_SIGNING_P12` (path to the key file) and `DUSTLING_SIGNING_P12_PASSWORD` when running `scripts/build-dmg.sh`. The key goes into a temporary keychain that is deleted when the script ends, never into your login keychain.
- **Never change the certificate** without meaning to: every user would have to turn Full Disk Access on again once.

## Developer ID (later)

With an Apple Developer account, the plan is to sign with a Developer ID certificate, turn on the hardened runtime, notarize and staple the disk image in the workflow, and publish a Homebrew cask. The website's brew command (`SHOW_BREW` in `src/site.ts`) stays hidden until the cask exists. Moving to Developer ID changes the requirement once, which costs every user one Full Disk Access re-grant.
