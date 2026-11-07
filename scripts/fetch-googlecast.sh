#!/bin/bash
# Downloads Google's official Cast SDK (static xcframework) into Vendor/.
# It's ~140 MB, so it's kept out of git. Run once after cloning, before building.
set -euo pipefail
VERSION="4.8.6"
SHA256="e1fe7fd6f2bf4b58e830d378fafc435d159bd755f7ee20fd3033aa1ce313cd6e"
URL="https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-${VERSION}_static.zip"

cd "$(dirname "$0")/.."
DEST="Vendor/GoogleCast.xcframework"
if [ -f "Vendor/.googlecast-$VERSION" ] && [ -d "$DEST" ]; then
  echo "Google Cast SDK $VERSION already present."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Google Cast SDK $VERSION…"
curl -fsSL -o "$TMP/cast.zip" "$URL"
echo "$SHA256  $TMP/cast.zip" | shasum -a 256 -c -
unzip -q "$TMP/cast.zip" -d "$TMP"
rm -rf Vendor && mkdir -p Vendor
mv "$TMP/GoogleCastSDK-ios-${VERSION}_static_xcframework/GoogleCast.xcframework" "$DEST"
touch "Vendor/.googlecast-$VERSION"
echo "Done: $DEST"
