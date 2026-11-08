#!/bin/bash
# Takes Mac App Store screenshots (2880 x 1800) using the debug screenshot mode.
# Usage: scripts/mac-screenshots.sh <server> <user> <password> <out dir>
set -uo pipefail
SERVER="$1"; USER_="$2"; PASS="$3"; OUT="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"
APP="build/dd/Build/Products/Debug/SoundBase.app/Contents/MacOS/SoundBase"
mkdir -p "$OUT"
shot() { # name scene [VAR=value ...]
  local name="$1" scene="$2"; shift 2
  env SB_DEMO_SERVER="$SERVER" SB_DEMO_USER="$USER_" SB_DEMO_PASS="$PASS" SB_SCENE="$scene" \
      SB_SNAPSHOT="$OUT/mac-$name.png" "$@" "$APP" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 40); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  kill $pid 2>/dev/null
  [ -f "$OUT/mac-$name.png" ] && echo "saved $name" || echo "FAILED $name"
}
shot 01-home home SB_PAUSE=1
shot 02-album-lyrics "album:Midnight Signals" SB_SEEK=22 SB_INSPECTOR=lyrics
shot 03-artist "artist:Aurora Lane" SB_SEEK=75 SB_PAUSE=1
shot 04-playlist-queue "playlist:Late Night Drive" SB_SEEK=40 SB_INSPECTOR=queue
shot 05-albums albums SB_PAUSE=1
