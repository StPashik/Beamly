#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build.sh
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid release version: %s\n' "$version" >&2
    exit 1
fi
archive="Beamly-$version-universal.zip"
mkdir -p dist Casks
python3 Scripts/package-media-sources.py
# Do not publish Finder metadata or local extended attributes in the archive.
ditto -c -k --norsrc --keepParent build/Beamly.app "dist/$archive"
(cd dist && shasum -a 256 "$archive" "Beamly-FFmpeg-Sources-$version.tar.xz" > SHA256SUMS)
archive_hash="$(awk 'NR == 1 { print $1; exit }' dist/SHA256SUMS)"
cat > Casks/beamly.rb <<EOF
cask "beamly" do
  version "$version"
  sha256 "$archive_hash"

  url "https://github.com/StPashik/Beamly/releases/download/v#{version}/Beamly-#{version}-universal.zip"
  name "Beamly"
  desc "Native AirPlay player for local videos"
  homepage "https://github.com/StPashik/Beamly"

  depends_on macos: :sonoma

  app "Beamly.app"

  caveats <<~EOS
    FFmpeg and ffprobe are included; no Homebrew media packages are required.
    This community build is ad-hoc signed and is not notarized by Apple.
    If macOS blocks the first launch, review System Settings > Privacy & Security.
    See https://github.com/StPashik/Beamly#first-launch for details.
  EOS
end
EOF
printf 'Release archive: %s/dist/%s\n' "$PWD" "$archive"
printf 'Commit the updated Casks/beamly.rb before tagging v%s.\n' "$version"
