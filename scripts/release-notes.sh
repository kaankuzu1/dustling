#!/usr/bin/env bash
# Prints the GitHub release notes for one version: its section of CHANGELOG.md, then how to
# install it.
#
#   scripts/release-notes.sh X.Y.Z [path/to/Dustling.dmg.sha256]
#
# Fails when CHANGELOG.md has no "## [X.Y.Z]" section, so a version can't be released without
# notes. With a .sha256 file, the notes also show the disk image's checksum.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: scripts/release-notes.sh X.Y.Z [Dustling.dmg.sha256]}"
CHECKSUM_FILE="${2:-}"
REPO_URL="https://github.com/kaankuzu1/dustling"

# Everything between "## [X.Y.Z]..." and the next "## [" heading or the link definitions at the
# end, without leading or trailing blank lines.
SECTION="$(awk -v heading="## [$VERSION]" '
  index($0, "## [") == 1 { if (found) exit; if (index($0, heading) == 1) { found = 1; next } }
  found && /^\[[^]]+\]: / { exit }
  found { lines[++n] = $0 }
  END {
    first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
    last = n; while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
    for (i = first; i <= last; i++) print lines[i]
  }
' "$ROOT/CHANGELOG.md")"

if [[ -z "$SECTION" ]]; then
  echo "error: CHANGELOG.md has no \"## [$VERSION]\" section (or it is empty)" >&2
  exit 1
fi

# Links like (docs/INSTALL.md) work in the repository but not on a release page, so point them at
# the files as they are in this version's tag.
SECTION="$(printf '%s\n' "$SECTION" \
  | BASE="$REPO_URL/blob/v$VERSION" perl -pe 's{\]\((?!https?:|mailto:|#)(?:\./)?([^)\s]+)\)}{]($ENV{BASE}/$1)}g')"

cat <<EOF
$SECTION

## Install

1. Download **Dustling.dmg** below, open it and drag **Dustling** to **Applications**.
2. Open Dustling. It isn't signed with an Apple Developer ID yet, so the first time, macOS stops it and asks you to confirm:
   - **macOS 15 Sequoia or later:** click **Done** in the message. Open **System Settings → Privacy & Security**, scroll down to **Security** and click **Open Anyway** next to "Dustling was blocked". Enter your password, then click **Open Anyway** once more.
   - **macOS 14 Sonoma:** Control-click Dustling in Applications, choose **Open**, then click **Open**.
3. Follow Dustling's setup to give it Full Disk Access.

**Updating from an earlier version?** Quit Dustling and replace it in Applications. macOS may stop honoring the old Full Disk Access switch for the new version; Dustling says so if it happens. Remove Dustling from the Full Disk Access list with the **−** button, then add it again with **+**.

More help, including what to do if macOS says the app is damaged: [Installing Dustling]($REPO_URL/blob/main/docs/INSTALL.md).
EOF

if [[ -n "$CHECKSUM_FILE" ]]; then
  echo
  echo "SHA-256 of Dustling.dmg: \`$(cut -d ' ' -f 1 "$CHECKSUM_FILE")\`"
fi
