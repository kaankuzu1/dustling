#!/usr/bin/env bash
# Builds Dustling.app for release and packs it into a disk image.
#
#   scripts/build-dmg.sh [--version X.Y.Z] [--require-signing]
#
# --version          Stop unless App/project.yml's MARKETING_VERSION is X.Y.Z. The release workflow
#                    passes the version from the git tag, so a tag can't ship a mismatched app.
# --require-signing  Stop unless the app gets Dustling's release signature (below). The release
#                    workflow passes it for tags, so a release can never go out ad hoc.
#
# The app is built in the Release configuration as a universal binary (Apple silicon and Intel).
# Dustling has no Developer ID signature yet, so macOS asks people to confirm the first time they
# open it (see docs/INSTALL.md).
#
# Signing: the build is signed ad hoc, then re-signed with Dustling's release certificate when the
# key is given in DUSTLING_SIGNING_P12_BASE64 (base64 of the PKCS#12 file) or DUSTLING_SIGNING_P12
# (its path), with the password in DUSTLING_SIGNING_P12_PASSWORD. macOS remembers Full Disk Access
# by the signature's requirement; with one certificate on every release that stays the same, so
# updates keep the permission. The certificate must be the one pinned in
# App/Signing/release-certificate.sha1 (DUSTLING_SIGNING_EXPECTED_SHA1 replaces it, for tests).
#
# Output, in dist/:
#   Dustling.dmg          Dustling.app and a link to /Applications in a laid-out window (see
#                         App/DMG). The name never changes, so
#                         .../releases/latest/download/Dustling.dmg always serves the newest release.
#   Dustling.dmg.sha256   its SHA-256, in the format `shasum -a 256 -c` reads.
#
# Needs Xcode 26 or later, XcodeGen (`brew install xcodegen`) and Python 3 (for dmgbuild, which the
# script installs into .build/ itself).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXPECTED_VERSION=""
REQUIRE_SIGNING=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) EXPECTED_VERSION="${2:?--version needs a value}"; shift 2 ;;
    --require-signing) REQUIRE_SIGNING=1; shift ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 64 ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1; }

# The single place the version lives. Plain `key: value` or `key: "value"`.
project_setting() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" App/project.yml | sed -n 1p
}

VERSION="$(project_setting MARKETING_VERSION)"
[[ -n "$VERSION" ]] || fail "couldn't read MARKETING_VERSION from App/project.yml"
if [[ -n "$EXPECTED_VERSION" && "$EXPECTED_VERSION" != "$VERSION" ]]; then
  fail "the tag says $EXPECTED_VERSION but App/project.yml has MARKETING_VERSION $VERSION"
fi

# Build number: the commit count, so every build from a later commit gets a higher number.
# CI must check out the full history (fetch-depth: 0) for this to be right.
if BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null)"; then :; else
  BUILD_NUMBER="$(project_setting CURRENT_PROJECT_VERSION)"
fi

DERIVED="$ROOT/.build/release-app"
DIST="$ROOT/dist"
APP_NAME="Dustling"
DMG="$DIST/$APP_NAME.dmg"

echo "==> Dustling $VERSION (build $BUILD_NUMBER)"
XCODE_VERSION="$(xcodebuild -version)"  # not piped into head: with pipefail, SIGPIPE would stop the script
echo "${XCODE_VERSION%%$'\n'*}"

echo "==> Generating the Xcode project"
command -v xcodegen >/dev/null || fail "XcodeGen is missing. Install it with: brew install xcodegen"
(cd App && xcodegen generate --quiet)

echo "==> Building (Release, arm64 + x86_64, signed afterwards)"
mkdir -p "$DERIVED"
rm -rf "$DERIVED/Build/Products/Release/$APP_NAME.app"
LOG="$DERIVED/xcodebuild.log"
# Signing is forced to ad hoc on the command line, so a personal App/Local.xcconfig can't change
# what gets published.
if ! xcodebuild \
  -project App/Dustling.xcodeproj \
  -scheme Dustling \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build > "$LOG" 2>&1
then
  grep -E '(error|fatal error):' "$LOG" | sort -u | head -n 40 >&2 || true
  echo "--- last lines of $LOG ---" >&2
  tail -n 40 "$LOG" >&2
  fail "xcodebuild failed (full log: $LOG)"
fi

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || fail "the build didn't produce $APP"

echo "==> Checking the app"
PLIST="$APP/Contents/Info.plist"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILT_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[[ "$BUILT_VERSION" == "$VERSION" ]] || fail "the app says version $BUILT_VERSION, expected $VERSION"
[[ "$BUILT_NUMBER" == "$BUILD_NUMBER" ]] || fail "the app says build $BUILT_NUMBER, expected $BUILD_NUMBER"
EXECUTABLE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
ARCHS_BUILT="$(lipo -archs "$EXECUTABLE")"
[[ " $ARCHS_BUILT " == *" arm64 "* && " $ARCHS_BUILT " == *" x86_64 "* ]] \
  || fail "expected a universal binary, got: $ARCHS_BUILT"
echo "    version $BUILT_VERSION, build $BUILT_NUMBER, architectures: $ARCHS_BUILT"

STAGE="$(mktemp -d -t dustling-dmg)"
MOUNT=""
KEYCHAIN=""
cleanup() {
  [[ -n "$MOUNT" ]] && hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  [[ -n "$KEYCHAIN" ]] && security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

# The key file, from a path or from base64 (how a CI secret arrives).
P12_FILE=""
if [[ -n "${DUSTLING_SIGNING_P12_BASE64:-}" ]]; then
  P12_FILE="$STAGE/signing.p12"
  printf '%s' "$DUSTLING_SIGNING_P12_BASE64" | base64 --decode > "$P12_FILE" \
    || fail "DUSTLING_SIGNING_P12_BASE64 isn't valid base64"
elif [[ -n "${DUSTLING_SIGNING_P12:-}" ]]; then
  [[ -f "$DUSTLING_SIGNING_P12" ]] || fail "DUSTLING_SIGNING_P12 points at $DUSTLING_SIGNING_P12, which doesn't exist"
  P12_FILE="$DUSTLING_SIGNING_P12"
fi

SIGNATURE="ad hoc"
if [[ -n "$P12_FILE" ]]; then
  echo "==> Signing with Dustling's release certificate"
  [[ -n "${DUSTLING_SIGNING_P12_PASSWORD:-}" ]] || fail "DUSTLING_SIGNING_P12_PASSWORD is missing"
  PINNED="${DUSTLING_SIGNING_EXPECTED_SHA1:-}"
  if [[ -z "$PINNED" ]]; then
    [[ -f App/Signing/release-certificate.sha1 ]] \
      || fail "App/Signing/release-certificate.sha1 is missing; see App/Signing/README.md"
    PINNED="$(tr -d '[:space:]' < App/Signing/release-certificate.sha1)"
  fi
  PINNED="$(printf '%s' "$PINNED" | tr 'A-F' 'a-f')"
  [[ "$PINNED" =~ ^[0-9a-f]{40}$ ]] || fail "the pinned certificate SHA-1 isn't 40 hex digits"

  # A keychain of its own, in a temporary folder and never on the search list: the key doesn't
  # touch the login keychain, and the cleanup trap deletes it.
  KEYCHAIN="$STAGE/signing.keychain-db"
  KEYCHAIN_PASSWORD="$(uuidgen)"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"  # no lock timeout
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security import "$P12_FILE" -k "$KEYCHAIN" -f pkcs12 -P "$DUSTLING_SIGNING_P12_PASSWORD" \
    -T /usr/bin/codesign > /dev/null 2>&1 || fail "couldn't import the signing key (wrong password?)"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN" > /dev/null 2>&1 || fail "couldn't let codesign use the signing key"

  # Not `find-identity -v`: a self-signed identity is listed as not trusted, which is fine here.
  IDENTITIES="$(security find-identity -p codesigning "$KEYCHAIN" | grep -E '^[[:space:]]+[0-9]+\)' || true)"
  [[ "$(printf '%s\n' "$IDENTITIES" | grep -c .)" -eq 1 ]] \
    || fail "expected one signing identity in the key file, found: ${IDENTITIES:-none}"
  IDENTITY="$(printf '%s' "$IDENTITIES" | awk '{print tolower($2)}')"
  [[ "$IDENTITY" == "$PINNED" ]] \
    || fail "the signing certificate isn't Dustling's release certificate; signing with another one would turn Full Disk Access off for everyone"

  # No entitlements on purpose: that drops the debug-only get-task-allow.
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --options runtime --timestamp=none "$APP" \
    || fail "codesign failed"
  codesign --verify --deep --strict "$APP" || fail "the signed app doesn't verify"
  REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
  WANT="identifier \"app.dustling.Dustling\" and certificate leaf = H\"$PINNED\""
  [[ "$REQUIREMENT" == "$WANT" ]] \
    || fail "the app's designated requirement is not the expected one. Got: $REQUIREMENT"
  SIGNATURE="Dustling release certificate ($PINNED)"
elif [[ $REQUIRE_SIGNING -eq 1 ]]; then
  fail "release builds must be signed with Dustling's certificate; see docs/RELEASING.md"
fi

echo "==> Packing $APP_NAME.dmg"
ditto "$APP" "$STAGE/$APP_NAME.app"
# Finder info or File Provider tags from an iCloud-synced checkout would break the signature.
xattr -cr "$STAGE/$APP_NAME.app"
codesign --verify --deep --strict "$STAGE/$APP_NAME.app" || fail "the app's signature doesn't verify"

# dmgbuild lays out the window (background, icon positions, no toolbar) by writing Finder's
# .DS_Store directly, so it works without a logged-in Finder, as on CI. It is pinned and installed
# into .build/ the first time.
DMGBUILD_VERSION="1.6.7"
DMGBUILD="${DMGBUILD:-$ROOT/.build/dmgbuild-venv/bin/dmgbuild}"
if [[ ! -x "$DMGBUILD" ]] || ! "$(dirname "$DMGBUILD")/python3" -c \
     "import importlib.metadata as m, sys; sys.exit(m.version('dmgbuild') != '$DMGBUILD_VERSION')" 2>/dev/null; then
  echo "    installing dmgbuild $DMGBUILD_VERSION into .build/dmgbuild-venv"
  rm -rf "$ROOT/.build/dmgbuild-venv"
  python3 -m venv "$ROOT/.build/dmgbuild-venv"
  "$ROOT/.build/dmgbuild-venv/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
  DMGBUILD="$ROOT/.build/dmgbuild-venv/bin/dmgbuild"
fi

VOLUME_ICON="$STAGE/$APP_NAME.app/Contents/Resources/AppIcon.icns"
[[ -f "$VOLUME_ICON" ]] || fail "the app has no AppIcon.icns for the disk icon"

mkdir -p "$DIST"
rm -f "$DMG" "$DMG.sha256"
# hdiutil (which dmgbuild drives) sometimes fails with "Resource busy" on CI machines; a retry
# clears it.
for attempt in 1 2 3; do
  if "$DMGBUILD" -s "$ROOT/App/DMG/dmg-settings.py" \
       -D app="$STAGE/$APP_NAME.app" \
       -D icon="$VOLUME_ICON" \
       -D background="$ROOT/App/DMG/background.png" \
       "$APP_NAME" "$DMG" > "$STAGE/dmgbuild.log" 2>&1; then
    break
  fi
  if [[ $attempt -eq 3 ]]; then
    tail -n 20 "$STAGE/dmgbuild.log" >&2
    fail "dmgbuild couldn't create the disk image"
  fi
  echo "    dmgbuild failed, trying again ($attempt/3)"
  rm -f "$DMG"
  sleep 5
done
hdiutil verify -quiet "$DMG" || fail "the disk image doesn't verify"

echo "==> Checking the disk image"
MOUNT="$(mktemp -d -t dustling-mount)"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
codesign --verify --deep --strict "$MOUNT/$APP_NAME.app" || fail "the app in the disk image doesn't verify"
echo "    signature: $SIGNATURE"
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || fail "the Applications link is missing"
for f in .DS_Store .background.tiff .VolumeIcon.icns; do
  [[ -e "$MOUNT/$f" ]] || fail "the disk image has no $f, so the window won't be laid out"
done
hdiutil detach -quiet "$MOUNT"
MOUNT=""

(cd "$DIST" && shasum -a 256 "$APP_NAME.dmg" > "$APP_NAME.dmg.sha256")

echo "==> Done"
echo "    $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "    SHA-256 $(cut -d ' ' -f1 "$DMG.sha256")"
