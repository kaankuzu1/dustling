# Installing Dustling

Dustling runs on macOS 14 Sonoma or later, on Apple silicon and Intel Macs.

## Download

Download **[Dustling.dmg](https://github.com/kaankuzu1/dustling/releases/latest/download/Dustling.dmg)**. It is always the newest release. Older versions and their notes are on the [Releases](https://github.com/kaankuzu1/dustling/releases) page.

Open the disk image and drag **Dustling** onto **Applications**. Then eject the disk image.

## Open it the first time

Dustling isn't signed with an Apple Developer ID or notarized by Apple yet. That costs a yearly fee and is planned. Until then, macOS stops Dustling the first time you open it, and you confirm once that you want to run it. The full source code is on GitHub, and every release is built from it by [GitHub Actions](../.github/workflows/release.yml).

### macOS 15 Sequoia and later

1. Open Dustling from Applications. macOS says it couldn't verify that Dustling is free of malware. Click **Done**.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to **Security**. Next to "Dustling was blocked to protect your Mac", click **Open Anyway**.
4. Enter your password or use Touch ID, then click **Open Anyway** in the message that appears.

The **Open Anyway** button shows up for about an hour after you tried to open the app. If it's gone, open Dustling again and go back to step 2.

### macOS 14 Sonoma

1. In Applications, Control-click (or right-click) **Dustling** and choose **Open**.
2. Click **Open** in the message.

### With Terminal

If you prefer, this removes the download mark that makes macOS ask:

```bash
xattr -dr com.apple.quarantine /Applications/Dustling.app
```

### "Dustling is damaged and can't be opened"

macOS shows this when the app's signature doesn't match its files, which usually means the download was interrupted or the app was copied in a way that changed it. Delete Dustling, download the disk image again and drag the app to Applications once more. If it still happens, use the Terminal command above, and please [open an issue](https://github.com/kaankuzu1/dustling/issues).

## Full Disk Access

macOS hides many caches, Mail downloads, iPhone backups and the Trash behind Full Disk Access. Dustling's setup walks you through turning it on in **System Settings → Privacy & Security → Full Disk Access**. Without it, Dustling still works and lists the places it couldn't read.

## Updating

1. Download the new **Dustling.dmg**.
2. Quit Dustling, then drag the new version onto **Applications** and choose **Replace**.
3. Open it. You confirm the first open again for each new version, as above.

From version 0.2.0 on, Full Disk Access stays on through updates, because every release is signed with the same certificate. If you update from an older version, macOS may still show the switch as on while no longer honoring it. Dustling checks this whenever it opens and tells you if access was lost. To fix it, select Dustling in the Full Disk Access list, remove it with the **−** button, then add it again with **+** (or from Dustling's setup).

## Check the download

Each release lists the SHA-256 checksum of `Dustling.dmg`, and has a `Dustling.dmg.sha256` file. In Terminal, in the folder with both files:

```bash
shasum -a 256 -c Dustling.dmg.sha256
```

It prints `Dustling.dmg: OK` when the file is intact.

## Uninstalling Dustling

Move Dustling from Applications to the Trash. To also remove its settings, run history and logs, move these to the Trash:

- `~/Library/Application Support/Dustling`
- `~/Library/Logs/Dustling`
- `~/Library/Preferences/app.dustling.Dustling.plist`

Then remove Dustling from **System Settings → Privacy & Security → Full Disk Access** with the **−** button.
