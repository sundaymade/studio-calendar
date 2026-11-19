#!/bin/bash
# Builds Studio Calendar.app into ~/Applications and restarts it.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/Studio Calendar.app"
pkill -x StudioCalendar 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/StudioCalendar "$APP/Contents/MacOS/StudioCalendar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Your own signing identity keeps permissions (Calendar, Contacts, Screen Recording) across rebuilds.
# Without one, the app is signed ad hoc and macOS may ask again after each build.
[ -f .signing ] && . ./.signing   # optional, not in git: SIGN_IDENTITY="<your identity hash>"
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null || codesign --force --sign - "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|Identifier" | head -2
open "$APP"
