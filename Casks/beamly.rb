cask "beamly" do
  version "1.0.2"
  sha256 "c27a597304ceb0a932ea1b4321731b63ca7b8e19f204f0941d88d2ce418c3e21"

  url "https://github.com/StPashik/Beamly/releases/download/v#{version}/Beamly-#{version}-universal.zip"
  name "Beamly"
  desc "Native AirPlay player for local videos"
  homepage "https://github.com/StPashik/Beamly"

  depends_on macos: :sonoma

  app "Beamly.app"

  caveats <<~EOS
    For MKV conversion and external subtitles: brew install ffmpeg-full
    Choose its bin folder in Beamly Settings if needed.
    This community build is ad-hoc signed and is not notarized by Apple.
    If macOS blocks the first launch, review System Settings > Privacy & Security.
    See https://github.com/StPashik/Beamly#first-launch for details.
  EOS
end
