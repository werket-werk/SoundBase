#!/bin/bash
# Takes App Store screenshots from a booted simulator using the debug screenshot mode.
# Usage: scripts/screenshots.sh <device name> <server> <user> <password> <out dir>
set -euo pipefail
DEVICE="$1"; SERVER="$2"; USER_="$3"; PASS="$4"; OUT="$5"
APP="build/dd/Build/Products/Debug-iphonesimulator/SoundBase.app"
BID="com.werket.soundbase"
mkdir -p "$OUT"
xcrun simctl install "$DEVICE" "$APP"
shot() { # name scene [extra env...]
  local name="$1" scene="$2"; shift 2
  xcrun simctl terminate "$DEVICE" "$BID" 2>/dev/null || true
  env SIMCTL_CHILD_SB_DEMO_SERVER="$SERVER" SIMCTL_CHILD_SB_DEMO_USER="$USER_" SIMCTL_CHILD_SB_DEMO_PASS="$PASS" \
      SIMCTL_CHILD_SB_SCENE="$scene" "$@" xcrun simctl launch "$DEVICE" "$BID" >/dev/null
  sleep "${WAIT:-7}"
  xcrun simctl io "$DEVICE" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
  echo "saved $name"
}
shot 01-home home SIMCTL_CHILD_SB_PLAY=1
shot 02-now-playing nowplaying SIMCTL_CHILD_SB_SEEK=72
shot 03-lyrics lyrics SIMCTL_CHILD_SB_SEEK=22
shot 04-album "album:Saltwater" SIMCTL_CHILD_SB_PLAY=1
shot 05-queue queue SIMCTL_CHILD_SB_SEEK=40
shot 06-library library SIMCTL_CHILD_SB_PLAY=1
shot 07-playlist "playlist:Late Night Drive"
shot 08-artist "artist:Aurora Lane" SIMCTL_CHILD_SB_PLAY=1
shot 09-search "search:aurora" SIMCTL_CHILD_SB_PLAY=1
