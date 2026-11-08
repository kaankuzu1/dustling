# Dustling for Mac

The SwiftUI app. It is built on the `DustlingCore` and `DustlingAppModel` libraries from the Swift package at the repository root.

## Build

Requirements: macOS 14 or newer, Xcode 16 or newer, and XcodeGen (`brew install xcodegen`).

```bash
cd App
xcodegen generate
xcodebuild -project Dustling.xcodeproj -scheme Dustling -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Dustling.app
```

You can also open `Dustling.xcodeproj` in Xcode after `xcodegen generate` and run the `Dustling` scheme. The project file is generated from `project.yml`, so change `project.yml` rather than the project, and don't commit `Dustling.xcodeproj` or `build/`.

## Signing

The app is not sandboxed, because it needs Full Disk Access. The project turns on the hardened runtime, but it only applies when you sign with a team: Xcode disables it for ad-hoc signing.

- Without a team, builds are signed with "Sign to Run Locally" (ad hoc), without the hardened runtime.
- To sign with your own team, create `App/Local.xcconfig` (it is git-ignored):

  ```
  DEVELOPMENT_TEAM = ABCDE12345
  CODE_SIGN_IDENTITY = Apple Development
  ```

macOS ties Full Disk Access to the code signature. With ad-hoc signing every rebuild has a new signature, so macOS may drop the grant after a rebuild. Dustling notices this: it re-checks Full Disk Access by reading a protected folder whenever it becomes active. Signing with a team keeps the grant across rebuilds.

## Full Disk Access

Open **System Settings > Privacy & Security > Full Disk Access** and switch Dustling on. Without it, Dustling still runs and says which places it can't read.

## Repository in iCloud Drive

If the repository sits in an iCloud-synced folder (Desktop or Documents), File Provider tags the built app with Finder information and `codesign` refuses to sign it. Two build phases handle this: one marks the build products folder as not synced (`com.apple.fileprovider.ignore#P`), and one clears extended attributes from the app before signing.

## Layout

- `Dustling/Theme/DustlingTheme.swift`: the Mosaic design tokens, copied unchanged from the approved handoff.
- `Dustling/Shell/`: the window shell (sidebar, footer, toolbar, action bar) and shared pieces (banner, chip, Mote, pixel icons, skeletons).
- `Dustling/Resources/Fonts/`: Geist, Geist Mono, Geist Pixel and Pixelify Sans (SIL OFL 1.1). `SOURCES.md` lists where each file came from and its SHA-256.
- `Dustling/Resources/Assets.xcassets/AppIcon.appiconset`: rendered from `docs/assets/dustling-icon.svg`.
