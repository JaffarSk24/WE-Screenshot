#!/bin/zsh
# Builds "WE Screenshot.app" as a universal binary (arm64 + x86_64), signs it
# and installs it into /Applications.
# Usage: tools/build_app.sh [--no-install]
# SIGN_IDENTITY overrides the certificate name (see tools/make_cert.sh);
# without that certificate the app is signed ad hoc, and macOS will ask for
# the Screen Recording permission again after every rebuild.
# ARCHS overrides the architectures, for example ARCHS=arm64.
# JOBS limits the number of parallel compile jobs, for example JOBS=4.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:-WE Screenshot Local Signing}"
BUNDLE_ID=sk.whiteeagles.screenshot
NAME="WE Screenshot"
EXE=WEScreenshot
MIN_OS=13.0
ARCHS=(${=ARCHS:-arm64 x86_64})
# The bundle is assembled outside the project folder: inside iCloud Drive the
# file provider keeps adding attributes that codesign rejects.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
mkdir -p build

# One build per architecture, joined with lipo. This works with the Command
# Line Tools alone; "swift build --arch a --arch b" needs the full Xcode.
SLICES=()
for arch in $ARCHS; do
  swift build -c release ${JOBS:+-j $JOBS} --triple "$arch-apple-macosx$MIN_OS" --scratch-path ".build/$arch" --product "$EXE"
  SLICES+=("$(swift build -c release ${JOBS:+-j $JOBS} --triple "$arch-apple-macosx$MIN_OS" --scratch-path ".build/$arch" --show-bin-path)/$EXE")
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$EXE"
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/$EXE")"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Optional built-in Google OAuth client, so that users only press "Sign In".
# The values live outside git (google-client.local or the environment) and are
# written into the staged Info.plist only; they are never printed.
G_ID="${WE_GOOGLE_CLIENT_ID:-}"
G_SECRET="${WE_GOOGLE_CLIENT_SECRET:-}"
if [[ -z "$G_ID" || -z "$G_SECRET" ]]; then
  G_ID=""
  G_SECRET=""
  if [[ -f google-client.local ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      key="${line%%=*}"
      value="${line#*=}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      if [[ "$value" == \"*\" && ${#value} -ge 2 ]] || [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
      fi
      case "$key" in
        CLIENT_ID) G_ID="$value" ;;
        CLIENT_SECRET) G_SECRET="$value" ;;
      esac
    done < google-client.local
  fi
fi
if [[ -n "$G_ID" && -n "$G_SECRET" ]]; then
  for pair in "WEGoogleClientID:$G_ID" "WEGoogleClientSecret:$G_SECRET"; do
    k="${pair%%:*}"
    v="${pair#*:}"
    /usr/libexec/PlistBuddy -c "Add :$k string $v" "$APP/Contents/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :$k $v" "$APP/Contents/Info.plist"
  done
  echo "Google client: built in"
else
  echo "Google client: none (google-client.local not found)"
fi
unset G_ID G_SECRET

cp -R Resources/*.lproj "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

xattr -cr "$APP"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
  echo "warning: certificate \"$IDENTITY\" not found, signing ad hoc (run tools/make_cert.sh)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true
ZIP="build/WE-Screenshot-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "packed $ZIP"

[[ "${1:-}" == "--no-install" ]] && exit 0

DEST="/Applications/$NAME.app"
if pgrep -x "$EXE" >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -x "$EXE" || true
fi
# Replace the files inside the existing bundle rather than the bundle itself.
mkdir -p "$DEST"
rsync -a --delete "$APP/" "$DEST/"
codesign --verify --strict "$DEST"
open "$DEST"
echo "installed $DEST"
