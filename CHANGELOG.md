# Changelog

Every change people will notice in Dustling is listed here, newest first.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While Dustling is at 0.x, a new feature raises the middle number (0.2.0) and a fix raises the last one (0.1.1). [docs/RELEASING.md](docs/RELEASING.md) explains how a version is released.

## [Unreleased]

### Fixed

- When Full Disk Access is off for this copy of Dustling but System Settings still shows it switched on, Dustling now says macOS is holding it for another copy and how to fix it (select Dustling, click −, drag this copy in). Setup also warns when you open Dustling from the disk image or Downloads.

## [0.1.2] - 2026-11-09

A polish release: every screen checked against the design in light and dark at every window size, smoother loading, an "All clean" state, and two fixes found while clicking through.

### Changed

- The sidebar shows what's waiting next to each tool: the junk a clean would move, how many apps the Uninstaller lists, and startup items to review.
- When a junk scan finds nothing to move, it says "All clean" with a sleepy Mote instead of a row of empty tiles and a 0 bytes total, and so does the Junk scan card on Home. Places that hold nothing say "Nothing to clean here right now", and the summary of a cleanup leaves them out.
- Loading placeholders fade into the content that replaces them, and the junk scan fades between scanning, results and the summary. Problem banners fade in instead of snapping into place. With Reduce Motion on, everything appears at once as before.
- "Xcode derived data and simulator caches" is now called "Xcode build data", so its name fits on its tile.
- While scanning, "5 of 9 places done" always shows in full; only the path being checked is shortened.
- After Put everything back, the junk scan's tiles say their items were put back and Scan again becomes the main button. An uninstall that was put back says "Everything was put back", and Done becomes the main button.
- "Check update size" on Home and other inline links look like links.
- The Dustling health page uses the full width of the window, like every other screen.
- Clearer wording for purgeable space on Home and for putting back a single item in History.

### Fixed

- Uninstalling an app whose launch agents weren't running reported each of them as "failed: could not unload", and turned the last-run light amber, although the files were moved. On macOS 26 and later launchctl gives a vague error for an agent that isn't loaded; Dustling now checks whether it's loaded before calling it a failure. Removing a startup item that was turned off no longer reports a failure either.
- After an uninstall, the app's row in the list could keep spinning instead of showing its check.

## [0.1.1] - 2026-11-09

A polish release: a proper install window, a Quit that always works, and fixes from a full pass over every screen.

### Changed

- The disk image now opens a proper install window: drag Dustling onto Applications, with a hint for updating an older copy and for the first open. The disk shows Dustling's icon.

### Fixed

- Quit works even when a confirmation or sheet is open. If Dustling is moving files, it asks before stopping.
- Loading placeholders now line up with the content that replaces them on every screen, show up on panels in light and dark, and fill the space without spilling over.
- On a first launch the sidebar opened too narrow, cutting off "Startup items" and the Full Disk Access line. It now always opens at its full width.
- Icons on buttons such as Move to Trash and Empty Trash stay visible in light mode when Dustling isn't the active app, and dim with their button when it can't be used.
- VoiceOver reads every line in a run's log in History, which it skipped before, and says whether each app in the Uninstaller was moved, left alone or is still waiting.
- The three tool cards on Home are the same height with their buttons in line, also in a narrow window where one caption takes two lines.
- Move to Trash in the Junk scan is off when nothing is selected to move, instead of only saying so after you click it.
- In the junk scan's "Close apps to include their files?" sheet, the "Clean without them" button was cut off. The sheet is wider and its buttons always show their full labels. The Uninstaller's "Quit … and move to Trash" button no longer gets cut off by a long app name.
- "Start scanning" at the end of the setup starts a new scan. Before, it showed the results of the scan from when Dustling opened, which could be minutes old.
- History lists the apps of a multi-app uninstall in the order they were removed. Runs that started within the same second used to appear in a random order.
- After putting an app back from the Uninstaller's summary, the "in the Trash" total no longer counts it.
- On macOS 26, the right edge of every screen was cut off by a few points when the window was at its smallest. The smallest window is now 8 points wider.

## [0.1.0] - 2026-11-08

The first release of Dustling: a free, open-source Mac cleaner that moves things to the Trash first and tells you what happened to every file.

### Added

- **Junk scan.** Finds caches, logs, old installers, Xcode and package manager leftovers and more, grouped into categories with their sizes and shown as a mosaic of your storage. Safe-to-regenerate categories are ticked by default; personal files such as big old downloads are only listed for you to review.
- **App uninstaller.** Moves apps to the Trash together with their leftovers: caches, preferences, containers, launch agents and more. Leftovers that may hold your own data (saves, libraries, databases) are listed but left unticked. It also finds apps without a bundle ID, such as Steam games.
- **Startup items.** Lists login agents and background daemons, and turns user-level ones off and on again.
- **History and Restore.** Every run is recorded with the outcome of each file. Put a whole run back, or a single file, as long as it is still in the Trash.
- **Empty Trash.** Lists what is in the Trash before the one permanent delete, and always asks first.
- **Health check.** Checks Full Disk Access by actually reading a protected place, and shows free space the way the macOS updater counts it, including purgeable space.
- **Guided setup** for Full Disk Access. Without it, Dustling still works and says which places it couldn't read.
- Light and dark appearance, VoiceOver and keyboard support, and motion that respects Reduce Motion.
- Runs on Apple silicon and Intel Macs with macOS 14 Sonoma or later.

### Known limitations

- Dustling isn't signed with an Apple Developer ID or notarized yet, so macOS asks you to confirm the first time you open it. [Installing Dustling](docs/INSTALL.md) shows how.
- Because of that, macOS may drop Full Disk Access when you update to a new version. Dustling tells you when this happens; turn it on again in System Settings.
- There is no admin helper yet. Items that need administrator rights (some system caches, launch daemons) are reported as "needs admin" and left alone.

[Unreleased]: https://github.com/kaankuzu1/dustling/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/kaankuzu1/dustling/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/kaankuzu1/dustling/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kaankuzu1/dustling/releases/tag/v0.1.0
