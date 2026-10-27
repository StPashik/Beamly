#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# This step runs on the maintainer's Mac; CI never receives the private signing key.
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
archive="Beamly-$version-universal.zip"
test -f "dist/$archive"
sparkle_tools="$PWD/.build/artifacts/sparkle/Sparkle/bin"
staging="$(mktemp -d "$PWD/dist/appcast.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
cp "dist/$archive" "$staging/$archive"
"$sparkle_tools/generate_appcast" --account app.peamer.mac \
    --download-url-prefix "https://github.com/StPashik/Beamly/releases/download/v$version/" \
    --link https://github.com/StPashik/Beamly --maximum-deltas 0 \
    -o "$staging/appcast.xml" "$staging"
"$sparkle_tools/sign_update" --account app.peamer.mac --verify "$staging/appcast.xml"
cp "$staging/appcast.xml" dist/appcast.xml
printf 'Signed update feed: %s/dist/appcast.xml\n' "$PWD"
