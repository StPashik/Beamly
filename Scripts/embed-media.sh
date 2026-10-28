#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_path="$1"
media="$PWD/.build/media-universal"
if [[ ! -f "$media/build.sha256" ]]; then
    printf 'Build bundled tools first: python3 Scripts/build-media.py\n' >&2
    exit 1
fi
mkdir -p "$app_path/Contents/Helpers" "$app_path/Contents/Resources/Media-Licenses"
ditto "$media/Licenses" "$app_path/Contents/Resources/Media-Licenses"
cp Docs/Bundled-media.md "$app_path/Contents/Resources/Media-Licenses/README.md"
for name in ffmpeg ffprobe; do
    tool="$app_path/Contents/Helpers/$name"
    ditto "$media/Helpers/$name" "$tool.new"
    lipo "$tool.new" -verify_arch arm64 x86_64
    codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$tool.new"
    # An already running helper must retain its original executable and code signature.
    mv -f "$tool.new" "$tool"
done
