cask "beamly" do
  version "1.0.1"
  sha256 "3180180fe51eab3e90447c09e9c04ebcdafac5cf56a02dcabf0ce67b130de52c"

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
