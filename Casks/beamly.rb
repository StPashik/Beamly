cask "beamly" do
  version "1.0.7"
  sha256 "85a5bb1942330fc8a9c6185627ea34342e39b8c01e3e50e73aae2f12b41d833d"

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
