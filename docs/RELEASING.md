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
   - Merge the pull request into `main`.

2. **Tag the merge commit and push the tag.**
   ```bash
   git switch main && git pull
   git tag -a v0.2.0 -m "Dustling 0.2.0"
   git push origin v0.2.0
   ```

3. **Let the workflow build it.** The tag starts the [Release workflow](../.github/workflows/release.yml). It runs the tests, checks that the tag matches `MARKETING_VERSION` and that CHANGELOG.md has a section for it, builds `Dustling.dmg`, and creates a **draft** release with the changelog section and install steps as its notes. Nothing is public yet.

4. **Check the draft.** Download `Dustling.dmg` from the draft release, open it on a Mac and try the new version. Read the notes.

5. **Publish.** On the draft release, click **Edit**, then **Publish release**. From then on, `https://github.com/kaankuzu1/dustling/releases/latest/download/Dustling.dmg` serves the new version, and so does the website's Download button.

6. **Update the website.** In the `dustling-website` repository, set `VERSION` in `src/site.ts` to the new version and merge.

If something is wrong after step 2, delete the draft release and the tag (`git push --delete origin v0.2.0` and `git tag -d v0.2.0`), fix it on `main`, and tag again.

## Building the disk image yourself

```bash
scripts/build-dmg.sh
```

It needs Xcode 26 or later and XcodeGen (`brew install xcodegen`), and writes `dist/Dustling.dmg` and `dist/Dustling.dmg.sha256`. The app is a universal binary (Apple silicon and Intel) with an ad hoc signature, the same as a release. `scripts/release-notes.sh 0.2.0` prints the notes a release would get.

Every pull request that touches the app, the package or these scripts also runs the Release workflow without publishing anything, so a broken build shows up before it reaches a tag. The disk image it builds is attached to the workflow run for 14 days.

## Signing (later)

Releases are signed ad hoc for now, so macOS asks people to confirm the first open ([INSTALL.md](INSTALL.md)) and may drop Full Disk Access after an update. With an Apple Developer account, the plan is to sign with a Developer ID certificate, turn on the hardened runtime, notarize and staple the disk image in the workflow, and publish a Homebrew cask. The website's brew command (`SHOW_BREW` in `src/site.ts`) stays hidden until the cask exists.
