cask "beamly" do
  version "1.0.3"
  sha256 "f956fcc91b5520974111fdbda5c4946e130bd94bd88343dece44f870355d9924"

  url "https://github.com/StPashik/Beamly/releases/download/v#{version}/Beamly-#{version}-universal.zip"
  name "Beamly"
  desc "Native AirPlay player for local videos"
  homepage "https://github.com/StPashik/Beamly"

  depends_on macos: :sonoma

  app "Beamly.app"

  caveats <<~EOS
    For MKV streaming and external subtitles: brew install ffmpeg-full
    Choose its bin folder in Beamly Settings if needed.
    This community build is ad-hoc signed and is not notarized by Apple.
    If macOS blocks the first launch, review System Settings > Privacy & Security.
    See https://github.com/StPashik/Beamly#first-launch for details.
  EOS
end
