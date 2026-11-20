#!/bin/zsh
# Builds "WE Screenshot.app" as a universal binary (arm64 + x86_64), signs it
# and installs it into /Applications.
# Usage: tools/build_app.sh [--no-install]
# SIGN_IDENTITY overrides the certificate name (see tools/make_cert.sh);
# without that certificate the app is signed ad hoc, and macOS will ask for
# the Screen Recording permission again after every rebuild.
# ARCHS overrides the architectures, for example ARCHS=arm64.
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
  swift build -c release --triple "$arch-apple-macosx$MIN_OS" --scratch-path ".build/$arch" --product "$EXE"
  SLICES+=("$(swift build -c release --triple "$arch-apple-macosx$MIN_OS" --scratch-path ".build/$arch" --show-bin-path)/$EXE")
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$EXE"
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/$EXE")"
cp Resources/Info.plist "$APP/Contents/Info.plist"
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
