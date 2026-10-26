<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Beamly app icon">
</p>

# Beamly

A native macOS player for sending local videos to Apple TV and other AirPlay receivers. Drop in a movie, choose your TV, and control playback from a compact, translucent window.

[Download the latest release](https://github.com/StPashik/Beamly/releases/latest) · [Report a bug](https://github.com/StPashik/Beamly/issues) · [MIT license](LICENSE)

## Features

- Native AirPlay device selection and local video preview.
- Direct playback of compatible MP4, M4V, and MOV files; FFmpeg conversion for MKV, AVI, and other formats.
- Audio-track selection, embedded subtitles, and external SRT, ASS, SSA, and VTT files.
- A persistent queue with resume positions, drag reordering, shuffle, repeat, and keyboard controls.
- Light and dark appearance, custom window controls, and Liquid Glass panels on macOS 26 or later. Earlier supported versions use standard translucent materials.
- No accounts, subscriptions, analytics, or bundled video content.

The current application interface is in Russian. The documentation and command-line installer are in English. Chromecast is not supported.

## Requirements

- **macOS 14 Sonoma or later**, on Apple Silicon or Intel. The release is a universal application.
- An Apple TV or compatible AirPlay receiver on the same local network.
- **FFmpeg and ffprobe** for conversion and external subtitles. Compatible MP4/MOV files can use AVFoundation without them.

Install FFmpeg with [Homebrew](https://brew.sh):

```sh
brew install ffmpeg
```

Beamly looks in `/opt/homebrew/bin`, `/usr/local/bin`, and the folder selected in Settings. FFmpeg is a separate dependency and is not included in the release archive.

## Install

### Download

1. Download `Beamly-1.0.0-universal.zip` from [Releases](https://github.com/StPashik/Beamly/releases/latest).
2. Extract it and move **Beamly.app** to **Applications**, or to your personal `~/Applications` folder.
3. See [First launch](#first-launch) before opening a downloaded build.

To verify the archive, download `SHA256SUMS` from the same release and run this in the download directory:

```sh
shasum -a 256 -c SHA256SUMS
```

### Homebrew

This repository also serves as a Homebrew tap. Use the explicit repository URL:

```sh
brew tap stpashik/beamly https://github.com/StPashik/Beamly.git
brew install --cask stpashik/beamly/beamly
```

The cask installs the universal app and FFmpeg, and verifies the archive's pinned SHA-256 checksum. This is a third-party tap, separate from Homebrew's official cask collection.

### npm

With Node.js 18 or later and npm installed:

```sh
npm install --global github:StPashik/Beamly#v1.0.0
beamly install
beamly
```

The npm package is a small installer and launcher for the native app. It downloads the matching GitHub release, checks its SHA-256 checksum and code-signature integrity, then installs into `~/Applications` without administrator access. FFmpeg is installed separately. It refuses to overwrite an existing application; quit and move the old app to the Trash before reinstalling. Your queue and settings are stored outside the application.

The command above installs directly from GitHub; it does not require the package to be published on the npm registry. There are no npm dependencies or automatic post-install scripts.

### First launch

**The community release is ad-hoc signed and is not notarized by Apple.** Its signature checks integrity; it does not provide an Apple-verified developer identity.

If macOS blocks opening the downloaded app, follow Apple's [instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445): try opening it, then review **System Settings → Privacy & Security → Open Anyway** if you trust this download. You can also [build the app yourself](#build-from-source). Do not disable Gatekeeper or System Integrity Protection.

Allow local-network access and incoming connections if macOS asks. An AirPlay receiver needs to fetch the selected video from your Mac.

## Use

1. Connect the Mac and receiver to the same network.
2. Click **AirPlay** in the top-right corner and select the receiver.
3. Drop a video or folder into the window, or press **⌘O**.
4. Use the speaker and subtitles menus beside the timeline to choose tracks.

| Shortcut | Action |
| --- | --- |
| ⌘O | Add videos |
| ⇧⌘O | Add an external subtitle file |
| Space | Play / pause |
| ← / → | Seek backward / forward 10 seconds |
| ⌘← / ⌘→ | Previous / next video |
| Delete | Remove the selected queue entry; keep the original file |
| ⌘. | Stop |
| ⌘, | Settings |

Option-click the green window button to zoom the window; a regular click enters full screen.

## Build from source

Building requires **Xcode 26 or later with the macOS 26 SDK**, including its Swift toolchain. Running the compiled app requires only macOS 14 or later.

```sh
git clone https://github.com/StPashik/Beamly.git
cd Beamly
Scripts/build.sh
open build/Beamly.app
```

The script builds and verifies both `arm64` and `x86_64` slices, assembles the app, includes the license and icon, and applies a local ad-hoc signature. No paid Apple Developer account or external Swift packages are required.

For development, open **Beamly.xcodeproj**, select the **Beamly** scheme and **My Mac**, and run. The Xcode project and Swift package share the same core library.

```sh
Scripts/test.sh                # Swift tests: HTTP, FFmpeg, queue, AVPlayer, and window behavior
Scripts/release.sh             # Universal ZIP, SHA256SUMS, and updated Homebrew cask
npm test                      # Installer integrity, existing-app protection, and real ZIP installation
npm pack --dry-run            # Inspect the files included in the npm package
```

Run `Scripts/release.sh` before `npm test`; the installation test uses the actual release ZIP. FFmpeg integration tests skip when FFmpeg is missing. Tests generate their own small videos and use isolated playlists, settings, and installation directories.

See [release instructions](Docs/RELEASING.md) and the [media HTTP contract](Docs/Media-HTTP.md). The icon's [PNG source](Resources/AppIcon.png) and [imagegen prompt](Resources/AppIcon.prompt.txt) are included; `swift Scripts/make-icon.swift Resources/AppIcon.icns` repacks its macOS sizes.

## Privacy and limitations

- Videos stay on your Mac and are streamed to your receiver. There is no cloud upload or telemetry.
- The local media server uses temporary, random capability URLs over HTTP. Anyone who obtains a complete URL can access that stream until playback is revoked. Use a trusted local network; do not expose the media port to the internet.
- Conversion uses H.264 video up to 1080p and stereo AAC audio. Direct playback preserves the original file. External subtitles are burned into converted video.
- Converted segments remain on disk until playback stops. Long movies need free disk space; encoding stops if less than 256 MiB remains. A crash can leave temporary files for macOS to clean up.
- The queue is stored at `~/Library/Application Support/Peamer/playlist.json`. The legacy directory and bundle identifier `app.peamer.mac` are retained so existing users keep their data. Removing the app or a queue entry does not remove original videos.
- Physical receiver compatibility, older macOS versions, Intel hardware, bitmap subtitles on real media, and network changes during playback need broader testing. Intel is cross-compiled; local runtime validation was on Apple Silicon.
- AirPlay discovery, selection, and authorization are handled by AVKit. Legacy standalone AirPlay pairing, Chromecast, automatic updates, and DRM-protected streaming services are outside the current scope.

## Contributing and license

Bug reports and focused pull requests are welcome. Include your macOS version, Mac architecture, receiver model, and a small reproducible example. Do not include private videos or complete media URLs in public reports. See [CONTRIBUTING.md](CONTRIBUTING.md).

Beamly's source code, documentation, and original icon are available under the [MIT license](LICENSE). FFmpeg is distributed separately under its own license. Beamly is an independent project; it is not affiliated with Apple or Beamer and includes no proprietary Beamer code or assets.
