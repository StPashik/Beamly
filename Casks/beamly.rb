cask "beamly" do
  version "1.0.11"
  sha256 "dc3ba6a882a8cd8cba46bbe6d94f944b3720deca3e02c1f8cfb302f26f6c0dc3"

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
