#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Studio Calendar.app and dist/Studio-Calendar-<version>.zip
# for GitHub Releases.
#
# Without settings the app is signed ad hoc: people open it once via System Settings > Privacy & Security >
# "Open Anyway". For a build that opens with a double click, set both:
#   RELEASE_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=<profile from `xcrun notarytool store-credentials`>
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/StudioCalendar
APP="dist/Studio Calendar.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StudioCalendar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/mail.py "$APP/Contents/Resources/mail.py"
xattr -cr "$APP"   # no ._ files in the zip
ZIP="dist/Studio-Calendar-$VERSION.zip"
if [ -n "${RELEASE_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements Resources/StudioCalendar.entitlements \
    --sign "$RELEASE_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
if [ -n "${RELEASE_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
fi
codesign -dv "$APP" 2>&1 | grep -E "Signature|Authority|Identifier" | head -3
echo "$ZIP ($(du -h "$ZIP" | cut -f1))"
