#!/usr/bin/env bash
# Assemble GcloudBar.app from a SwiftPM release build. Needs only the Xcode
# toolchain; the app has no path into this repo at runtime.
#
# Usage: build.sh [target.app]   (default ~/Applications/GcloudBar.app)
#   VERSION               CFBundleShortVersionString (default: latest git tag, else 0.0.0-dev)
#   UNIVERSAL=1           build for arm64 and x86_64 (release builds)
#   GCLOUDBAR_BUNDLE_ID   bundle identifier (default com.michieltimmerman.gcloudbar)
#   CODESIGN_IDENTITY     signing identity, "-" for ad-hoc. Unset: the first Developer
#                         ID / Apple Development identity in the keychain, else ad-hoc.
#                         A Developer ID gets the hardened runtime and a timestamp, as
#                         notarization requires.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Applications/GcloudBar.app}"
BUNDLE_ID="${GCLOUDBAR_BUNDLE_ID:-com.michieltimmerman.gcloudbar}"
TAG="$(git -C "$PKG_DIR" describe --tags --abbrev=0 2> /dev/null || true)"
VERSION="${VERSION:-${TAG#v}}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD="$(git -C "$PKG_DIR" rev-list --count HEAD 2> /dev/null || echo 1)"

ARCH_FLAGS=()
if [ "${UNIVERSAL:-}" = 1 ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c release "${ARCH_FLAGS[@]}" --package-path "$PKG_DIR"
BIN_PATH="$(swift build -c release "${ARCH_FLAGS[@]}" --package-path "$PKG_DIR" --show-bin-path)/GcloudBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/GcloudBar"
cp "$PKG_DIR/packaging/GcloudBar.icns" "$APP/Contents/Resources/GcloudBar.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>GcloudBar</string>
  <!-- Notification authorization is cached per bundle id and cannot be reset from
       the CLI, so a denial recorded against an old id needs a new one. -->
  <key>CFBundleIdentifier</key><string>BUNDLE_ID</string>
  <key>CFBundleName</key><string>GcloudBar</string>
  <key>CFBundleDisplayName</key><string>GcloudBar</string>
  <key>CFBundleIconFile</key><string>GcloudBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>VERSION</string>
  <key>CFBundleVersion</key><string>BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Michiel Timmerman. MIT License.</string>
</dict>
</plist>
PLIST
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"

# Notifications work with any signature. macOS grants UNUserNotificationCenter
# only to a Developer ID build ("UNErrorDomain Code=1: Notifications are not
# allowed for this application" for ad-hoc and Apple Development alike); other
# builds post through the deprecated NSUserNotificationCenter instead.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')
fi

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
  echo "ad-hoc signed"
elif [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  # A release build: failing to sign must fail the build, not ship unsigned.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "signed: $IDENTITY (hardened runtime)"
elif codesign --force --sign "$IDENTITY" "$APP" > /dev/null 2>&1; then
  echo "signed: $IDENTITY"
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "signing with $IDENTITY failed" >&2
  exit 1
else
  codesign --force --sign - "$APP"
  echo "signing with $IDENTITY failed, fell back to ad-hoc"
fi
codesign --verify --strict "$APP"

echo "built $APP ($VERSION, build $BUILD$( [ "${UNIVERSAL:-}" = 1 ] && echo ", universal"))"
