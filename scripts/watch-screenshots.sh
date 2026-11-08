#!/bin/bash
# Takes Apple Watch App Store screenshots using the debug screenshot mode.
# Usage: scripts/watch-screenshots.sh <watch simulator name> <server> <user> <password> <out dir>
set -euo pipefail
DEVICE="$1"; SERVER="$2"; USER_="$3"; PASS="$4"; OUT="$5"
APP="build/dd/Build/Products/Debug-watchsimulator/SoundBaseWatch.app"
BID="com.werket.soundbase.watchkitapp"
mkdir -p "$OUT"
xcrun simctl install "$DEVICE" "$APP"
shot() { # name scene
  xcrun simctl terminate "$DEVICE" "$BID" 2>/dev/null || true
  SIMCTL_CHILD_SB_DEMO_SERVER="$SERVER" SIMCTL_CHILD_SB_DEMO_USER="$USER_" SIMCTL_CHILD_SB_DEMO_PASS="$PASS" \
    SIMCTL_CHILD_SB_SCENE="$2" xcrun simctl launch "$DEVICE" "$BID" >/dev/null
  sleep "${3:-8}"
  xcrun simctl io "$DEVICE" screenshot --type=png "$OUT/watch-$1.png" >/dev/null 2>&1
  echo "saved $1"
}
shot 01-library home 7
shot 02-remote remote 7
shot 03-album album 9
shot 04-downloaded downloaded 14
shot 05-now-playing nowplaying 8
