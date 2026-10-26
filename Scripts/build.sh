#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/beamly-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/private/tmp}/beamly-spm-cache"
build_flags=(-c release --arch arm64 --arch x86_64 --disable-sandbox --cache-path .build/cache)
swift build "${build_flags[@]}"
bin_path="$(swift build "${build_flags[@]}" --show-bin-path)"
lipo "$bin_path/Beamly" -verify_arch arm64 x86_64
app_path="$PWD/build/Beamly.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# Replace the executable atomically so an already running player can keep playing.
cp "$bin_path/Beamly" "$app_path/Contents/MacOS/Beamly.new"
mv -f "$app_path/Contents/MacOS/Beamly.new" "$app_path/Contents/MacOS/Beamly"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp LICENSE "$app_path/Contents/Resources/LICENSE"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Built %s\n' "$app_path"
