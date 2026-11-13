#!/bin/zsh
# Opens Dustling in every screen state, at its smallest, default and a large window size, and checks
# each one: every window and sheet is saved as a picture, and every control must have a name
# VoiceOver can read and must not be cut off by the edge of its window or sheet. See
# docs/RELEASING.md, "QA pass".
#
#   scripts/qa-screens.sh                   # every state, light and dark
#   scripts/qa-screens.sh --looks dark      # one appearance (layout is the same in both)
#   scripts/qa-screens.sh --only uninstaller # states whose name contains this
#
# It writes dist/qa/<time>/: one folder per state and appearance with the pictures, the
# accessibility tree (.txt) and report.txt, plus index.html to look through them all. The exit status
# is 1 if any state has a problem.
#
# It never touches your Dustling or your files. It builds a separate copy (bundle ID
# app.dustling.Dustling.qa, so its settings are its own), runs the fixtures' sample data, and points
# the real-data states at sample home folders it makes in a temporary folder (CFFIXED_USER_HOME).
# Nothing is moved, cleaned or turned off: no state presses a button.
set -euo pipefail

ROOT=${0:A:h:h}
LOOKS=(light dark)
ONLY=""
while (( $# )); do
  case $1 in
    --looks) LOOKS=(${(s:,:)2}); shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done

QA_ID=app.dustling.Dustling.qa
OUT=$ROOT/dist/qa/$(date +%Y%m%d-%H%M%S)
BUILD=$ROOT/.build/qa-app
WORK=$(mktemp -d -t dustling-qa)
mkdir -p "$OUT"
trap 'rm -rf "$WORK"; defaults delete $QA_ID >/dev/null 2>&1 || true' EXIT

echo "Building the QA copy…"
(cd "$ROOT/App" && xcodegen generate --quiet)
# Whole-module, like Release. An incremental Debug build can compile a file against the concrete type
# behind another file's `some View` (e.g. `skeleton(_:index:)`), then not recompile it when that
# function's body changes; the stale object reads the new layout wrong and the QA copy crashes.
xcodebuild -project "$ROOT/App/Dustling.xcodeproj" -scheme Dustling -configuration Debug \
  -derivedDataPath "$BUILD" PRODUCT_BUNDLE_IDENTIFIER=$QA_ID SWIFT_COMPILATION_MODE=wholemodule \
  build -quiet > "$OUT/xcodebuild.log" 2>&1 \
  || { tail -30 "$OUT/xcodebuild.log"; exit 1; }
APP=$BUILD/Build/Products/Debug/Dustling.app

# Sample home folders: one empty (the empty states) and one with many small, oddly named items.
EMPTY_HOME=$WORK/empty-home
SAMPLE_HOME=$WORK/sample-home
mkdir -p "$EMPTY_HOME"
make_sample_home() {
  local H=$1 L=$1/Library
  file() { mkdir -p "${1:h}"; head -c ${2:-4096} /dev/zero > "$1"; }
  for i in {1..80}; do file "$L/Caches/com.example.app$i/Cache.db" $((i * 900)); done
  file "$L/Caches/com.example.a-very-long-bundle-identifier-for-an-app-that-likes-long-names.helper/data" 20000
  file "$L/Caches/Türkçe Önbellek ğüşiöç/blob" 9000
  file "$L/Caches/Emoji 🧹 Cache/blob" 9000
  for i in {1..40}; do file "$L/Logs/App$i/app.log" 3000; done
  file "$L/Developer/Xcode/DerivedData/Another_Really_Long_Project_Name_That_Goes_On_And_On-qwertyuiop/Build/x.o" 30000
  file "$H/.npm/_cacache/content-v2/sha512/aa" 40000
  file "$H/.Trash/old-notes.txt" 3000
  local name id
  for i in {1..30}; do
    if (( i == 1 )); then name="An App With An Extremely Long Name That Will Not Fit In Its Row At All"; else name="Sample App $i"; fi
    id=com.example.sample$i
    mkdir -p "$H/Applications/$name.app/Contents/MacOS"
    file "$H/Applications/$name.app/Contents/MacOS/$name" 20000
    cat > "$H/Applications/$name.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$id</string><key>CFBundleName</key><string>$name</string><key>CFBundleExecutable</key><string>$name</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
    file "$L/Application Support/$name/data" 5000
    file "$L/Preferences/$id.plist" 400
  done
  # Older than any "recently changed" cut-off, so the scan lists them.
  find "$H" -exec touch -h -t 202501010000 {} +
}
make_sample_home "$SAMPLE_HOME"

# name | home | launch arguments
STATES=(
  "home-ready||-DustlingHomeFixture ready -DustlingUninstallerFixture list -DustlingStartupFixture normal"
  "home-limited||-DustlingHomeFixture limited"
  "junk-scanning||-DustlingHomeFixture scanning"
  "junk-empty-trash||-DustlingHomeFixture emptytrash"
  "junk-empty-trash-problems||-DustlingHomeFixture emptytrashproblems"
  "junk-review-files||-DustlingHomeFixture reviewfiles"
  "junk-close-apps||-DustlingHomeFixture closeapps"
  "junk-done||-DustlingHomeFixture done"
  "junk-moving-password||-DustlingHomeFixture moving -DustlingPasswordFixture YES"
  "junk-putback-password||-DustlingHomeFixture done -DustlingPasswordFixture YES"
  "junk-empty-trash-password||-DustlingHomeFixture emptytrash -DustlingPasswordFixture YES"
  "uninstaller-list||-DustlingUninstallerFixture list"
  "uninstaller-detail||-DustlingUninstallerFixture detail"
  "uninstaller-review||-DustlingUninstallerFixture review"
  "uninstaller-confirm||-DustlingUninstallerFixture confirm"
  "uninstaller-confirm-all||-DustlingUninstallerFixture confirm-all"
  "uninstaller-confirm-limited||-DustlingUninstallerFixture confirm-limited"
  "uninstaller-removing||-DustlingUninstallerFixture removing"
  "uninstaller-done||-DustlingUninstallerFixture done"
  "uninstaller-removing-password||-DustlingUninstallerFixture removing -DustlingPasswordFixture YES"
  "startup-normal||-DustlingStartupFixture normal"
  "startup-remove||-DustlingStartupFixture remove"
  "startup-changed||-DustlingStartupFixture changed"
  "history-runs||-DustlingHistoryFixture runs"
  "history-items||-DustlingHistoryFixture items"
  "history-log||-DustlingHistoryFixture log"
  "history-restored||-DustlingHistoryFixture restored"
  "history-restoring-password||-DustlingHistoryFixture restoring -DustlingPasswordFixture YES"
  "repair-helper||-DustlingRepairFixture helper"
  "repair-fda||-DustlingRepairFixture fda"
  "repair-results||-DustlingRepairFixture results"
  "repair-retrying-password||-DustlingRepairFixture results -DustlingPasswordFixture YES"
  "onboarding-1||-DustlingOnboardingStep 1 -DustlingHomeFixture ready"
  "onboarding-2||-DustlingOnboardingStep 2 -DustlingHomeFixture ready"
  "onboarding-3||-DustlingOnboardingStep 3 -DustlingHomeFixture ready"
  "onboarding-4||-DustlingOnboardingStep 4 -DustlingHomeFixture ready"
  "settings-general||-DustlingSettingsSection general -DustlingHomeFixture ready"
  "settings-exclusions||-DustlingSettingsSection exclusions -DustlingHomeFixture ready"
  "settings-about||-DustlingSettingsSection about -DustlingHomeFixture ready"
  "empty-home|empty|-DustlingScreen home -DustlingQAAssumeFullDiskAccess YES"
  "empty-junk|empty|-DustlingScreen junkScan -DustlingQAAssumeFullDiskAccess YES"
  "empty-history|empty|-DustlingScreen history -DustlingQAAssumeFullDiskAccess YES"
  "empty-health|empty|-DustlingScreen diagnostics -DustlingQAAssumeFullDiskAccess YES"
  "nofda-uninstaller|empty|-DustlingScreen uninstaller"
  "sample-junk|sample|-DustlingScreen junkScan -DustlingQAAssumeFullDiskAccess YES"
  "sample-uninstaller|sample|-DustlingScreen uninstaller -DustlingQAAssumeFullDiskAccess YES"
  "sample-startup|sample|-DustlingScreen startupItems -DustlingQAAssumeFullDiskAccess YES"
)

failed=()
for entry in $STATES; do
  name=${entry%%|*}; rest=${entry#*|}; home=${rest%%|*}; args=${rest#*|}
  [[ -n $ONLY && $name != *$ONLY* ]] && continue
  case $home in
    empty) home_dir=$EMPTY_HOME ;;
    sample) home_dir=$SAMPLE_HOME ;;
    *) home_dir=$EMPTY_HOME ;;
  esac
  for look in $LOOKS; do
    dir=$OUT/$name-$look
    defaults write $QA_ID appearance $look
    defaults write $QA_ID onboardingCompleted -bool true
    defaults delete $QA_ID "NSWindow Frame main" >/dev/null 2>&1 || true
    defaults delete $QA_ID "NSSplitView Subview Frames main, SidebarNavigationSplitView" >/dev/null 2>&1 || true
    printf '%-30s %-5s ' $name $look
    # -g: in the background, so it doesn't take the keyboard from you.
    if open -W -g -n --env CFFIXED_USER_HOME="$home_dir" "$APP" --args \
        -ApplePersistenceIgnoreState YES -DustlingLayoutCheck "$dir" ${(z)args} \
        && [[ -f $dir/report.txt ]] && grep -q '^No problems found' "$dir/report.txt"; then
      echo ok
    else
      echo PROBLEMS
      [[ -f $dir/report.txt ]] || { mkdir -p "$dir"; echo "No report: Dustling quit before the check finished. See ~/Library/Logs/DiagnosticReports." > "$dir/report.txt"; }
      failed+=("$name-$look")
    fi
  done
done

# A page to look through every picture.
{
  echo '<!doctype html><meta charset="utf-8"><title>Dustling QA</title>'
  echo '<style>body{font:13px -apple-system;margin:24px;background:#f4f5f7}h2{margin:28px 0 6px}img{max-width:32%;margin:4px;border:1px solid #ccc;vertical-align:top}pre{color:#b42318;white-space:pre-wrap}</style>'
  for dir in $OUT/*(/); do
    echo "<h2>${dir:t}</h2>"
    grep -qv '^No problems found' "$dir/report.txt" 2>/dev/null && echo "<pre>$(sed 's/&/\&amp;/g; s/</\&lt;/g' "$dir/report.txt")</pre>"
    for img in $dir/*.png(N); do echo "<a href=\"${dir:t}/${img:t}\"><img src=\"${dir:t}/${img:t}\" title=\"${img:t}\"></a>"; done
  done
} > "$OUT/index.html"

echo
echo "Pictures and reports: $OUT/index.html"
if (( ${#failed} )); then
  echo "Problems in ${#failed} states:"
  for f in $failed; do echo "  $f"; sed 's/^/    /' "$OUT/$f/report.txt" 2>/dev/null | head -20; done
  exit 1
fi
echo "No problems found."
