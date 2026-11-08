# Changelog

Every change people will notice in Dustling is listed here, newest first.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While Dustling is at 0.x, a new feature raises the middle number (0.2.0) and a fix raises the last one (0.1.1). [docs/RELEASING.md](docs/RELEASING.md) explains how a version is released.

## [Unreleased]

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

[Unreleased]: https://github.com/kaankuzu1/dustling/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kaankuzu1/dustling/releases/tag/v0.1.0
