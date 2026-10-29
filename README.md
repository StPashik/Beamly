<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Beamly app icon">
</p>

# Beamly

A native macOS player for sending local videos to Apple TV and other AirPlay receivers. Drop in a movie, choose your TV, and control playback from a compact, translucent window.

[Download the latest release](https://github.com/StPashik/Beamly/releases/latest) · [Report a bug](https://github.com/StPashik/Beamly/issues) · [MIT license](LICENSE)

## Features

- Native AirPlay device selection and a static thumbnail from the middle of the video.
- Direct playback of compatible MP4, M4V, and MOV files; quality-preserving 4K HEVC/H.264 remuxing from MKV, including supported HDR10/HLG streams.
- Audio-track selection, embedded subtitles, and external SRT, ASS, SSA, and VTT files.
- Saved audio and subtitle language preferences, applied to each video when opened.
- Playback preparation and buffering status, with explanations for original-quality streaming, compatibility conversion, and software-encoder retries.
- Standalone FFmpeg and FFprobe included with the app; see [bundled media tools](Docs/Bundled-media.md).
- A persistent queue with resume positions, drag reordering, shuffle, repeat, and keyboard controls.
- Light and dark appearance, custom window controls, and Liquid Glass panels on macOS 26 or later. Earlier supported versions use standard translucent materials.
- English, Russian, German, French, and Spanish interfaces, selectable in Settings. English is the default.
- Manual update checks and installation through Sparkle, with signed update feeds and archives.
- No accounts, subscriptions, analytics, or bundled video content.

Chromecast is not supported. See [video quality and AirPlay](Docs/Media-Streaming.md) for supported profiles, subtitles, audio, and verification limits.

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations.**

## Requirements

- **macOS 14 Sonoma or later**, on Apple Silicon or Intel. The release is a universal application.
- An Apple TV or compatible AirPlay receiver on the same local network.
- **FFmpeg and ffprobe are included** for MKV streaming, external subtitles, and compatibility conversion. No Homebrew installation or separate codec download is required.

For **Beamly 1.0.3 and earlier**, FFmpeg was a separate dependency. Users of those versions can update Beamly or install subtitle-capable FFmpeg with [Homebrew](https://brew.sh):

```sh
brew install ffmpeg-full
```

Beamly uses the folder selected in Settings first, then bundled helpers, legacy resource-folder tools, Homebrew's `ffmpeg-full` installation, and the standard `/opt/homebrew/bin` and `/usr/local/bin` directories. The full Homebrew build includes the `subtitles` filter required for burning text subtitles; the regular formula may omit it. Beamly 1.0.4 bundles this functionality, including HDR-to-SDR conversion, with complete corresponding source and license notices.

When using Beamly 1.0.0, select the `ffmpeg-full` bin folder in Settings if it is not detected: `/opt/homebrew/opt/ffmpeg-full/bin` on Apple Silicon or `/usr/local/opt/ffmpeg-full/bin` on Intel.

## Install

### Download

1. Download `Beamly-1.0.7-universal.zip` from [Releases](https://github.com/StPashik/Beamly/releases/latest).
2. Extract it and move **Beamly.app** to **Applications**, or to your personal `~/Applications` folder.
3. See [First launch](#first-launch) before opening a downloaded build.

To verify the app ZIP, download `SHA256SUMS` from the same release and run this in the download directory:

```sh
awk '$2 == "Beamly-1.0.7-universal.zip"' SHA256SUMS | shasum -a 256 -c -
```

The same checksum file also lists `Beamly-FFmpeg-Sources-1.0.7.tar.xz`, the complete corresponding source for the bundled media tools. If both archives are downloaded, `shasum -a 256 -c SHA256SUMS` verifies both.

### Homebrew

This repository also serves as a Homebrew tap. Use the explicit repository URL:

```sh
brew tap stpashik/beamly https://github.com/StPashik/Beamly.git
brew install --cask stpashik/beamly/beamly
```

The cask installs the universal app and verifies the archive's pinned SHA-256 checksum. FFmpeg and ffprobe are included; installing Beamly does not upgrade your existing Homebrew media-tool dependencies. This is a third-party tap, separate from Homebrew's official cask collection.

### npm

With Node.js 18 or later and npm installed (omit `--allow-git=root` on npm 11 or earlier):

```sh
npm install --global --allow-git=root github:StPashik/Beamly#v1.0.7
beamly install
beamly
```

The npm package is a small installer and launcher for the native app. It downloads the matching GitHub release, checks its SHA-256 checksum and code-signature integrity, then installs into `~/Applications` without administrator access. FFmpeg and ffprobe are included in the downloaded app. The installer refuses to overwrite an existing application; quit and move the old app to the Trash before reinstalling. Your queue and settings are stored outside the application.

The command above installs directly from GitHub; it does not require the package to be published on the npm registry. npm 12 requires explicit permission for the requested GitHub dependency. There are no npm dependencies or automatic post-install scripts. The flag is per-command; no global npm configuration needs to be changed.

### First launch

**The community release is ad-hoc signed and is not notarized by Apple.** Its signature checks integrity; it does not provide an Apple-verified developer identity.

If macOS blocks opening the downloaded app, follow Apple's [instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445): try opening it, then review **System Settings → Privacy & Security → Open Anyway** if you trust this download. You can also [build the app yourself](#build-from-source). Do not disable Gatekeeper or System Integrity Protection.

Allow local-network access and incoming connections if macOS asks. An AirPlay receiver needs to fetch the selected video from your Mac.

## Use

1. Connect the Mac and receiver to the same network.
2. Click **AirPlay** in the top-right corner and select the receiver.
3. Drop a video or folder into the window, or press **⌘O**. Playback starts only after an AirPlay device is connected; disconnecting pauses the player. Pressing Play without a connection opens the AirPlay device picker directly, and playback begins after you connect a receiver.
4. Use the speaker and subtitles menus beside the timeline to choose tracks.

Beamly finds SRT, ASS, SSA, and VTT files beside the video when their names match, for example `Movie.mkv` with `Movie.srt` or `Movie.ru.srt`. It selects an exact-basename match or the only matching file automatically. When several language files match, choose one in the subtitles menu.

In **Settings → Track preferences**, choose an audio language or **Original audio**, and a subtitle language or **Off**. These independent choices are saved across launches and applied when opening each video, including the next queue entry. Manual track changes affect the current video and survive seeking and subtitle timing changes. Missing preferred audio falls back to the file's default track; missing preferred subtitles stay off. **Original audio** requires an explicit original-track marker in the file; Beamly does not guess the original language. The initial **File default / Automatic** settings retain the adjacent-subtitle behavior above.

Choose **Subtitles → Subtitle timing…** to move captions earlier or later in 0.5-second steps, or reset the correction. Positive values show subtitles later. Each movie's correction is saved with its queue entry and survives relaunches; removing that entry also removes its correction. Original video and subtitle files are never changed.

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

The window stays 674 points wide. Resize its height or use the green button to zoom vertically. The preview shows a still frame from the middle of the source video; it does not play or follow the timeline.

The status beside the preview follows file inspection, stream preparation, subtitles, and loading. **Buffering…** appears when AVPlayer reports that it is waiting to avoid a playback stall; its brief initial buffer evaluation is shown as **Starting playback…**. Pause remains available while buffering. Without a connected receiver, the status asks you to choose an AirPlay device.

The quality line distinguishes direct/original-quality delivery from **compatibility conversion up to 1080p SDR**; small videos are not enlarged to 1080p. The explanation below identifies the quality setting, a video format requiring conversion, or a retry with the software encoder. Hover over a long explanation to read it in full. These states do not estimate a completion percentage, diagnose Wi-Fi quality, or certify physical receiver output.

## Language and updates

Open **Beamly → Settings → Language** to choose English, Russian, German, French, or Spanish. Restart Beamly to apply the selection to the interface and native dialogs. English is used on first launch, regardless of the system language. Your queue and preferences are preserved.

Choose **Beamly → Check for Updates…** or use the same button in **Settings → Updates**. Sparkle checks the latest GitHub release, verifies the signed feed and archive, and offers to download, install, and relaunch. Checks and installations only start when you request them.

The updater is included starting with **1.0.1**. Users of 1.0.0 must install 1.0.1 or later through the ZIP, Homebrew, or npm first. Homebrew users can also run:

~~~sh
brew update
brew upgrade --cask stpashik/beamly/beamly
~~~

## Build from source

Building requires **Xcode 26 or later with the macOS 26 SDK**, Python 3.12+, CMake, pkg-config, and make. The build downloads and compiles pinned media sources for both CPUs; subsequent matching builds reuse the generated tools. Running the compiled app requires only macOS 14 or later.

```sh
git clone https://github.com/StPashik/Beamly.git
cd Beamly
Scripts/build.sh
open build/Beamly.app
```

The script builds and verifies both `arm64` and `x86_64` slices, assembles the app, includes the license and icon, and applies a local ad-hoc signature. No paid Apple Developer account is required. Swift Package Manager downloads the pinned [Sparkle](https://sparkle-project.org) update framework; its license is included in the app.

For development, run `python3 Scripts/build-media.py` first, then open **Beamly.xcodeproj**, select your development team in **Signing & Capabilities**, then select the **Beamly** scheme and **My Mac**, and run. Xcode uses Apple Development signing with hardened runtime; its embedded Sparkle framework and media helpers use the same identity. Use the script above for a local ad-hoc build without a development signing identity. The Xcode project and Swift package share the same core library.

```sh
BEAMLY_TEST_APP_BUNDLE="$PWD/build/Beamly.app" Scripts/test.sh # Test the bundled media pipeline
Scripts/release.sh             # Universal ZIP, SHA256SUMS, and updated Homebrew cask
npm test                      # Installer integrity, existing-app protection, and real ZIP installation
npm pack --dry-run            # Inspect the files included in the npm package
```

Run `Scripts/release.sh` before `npm test`; the installation test uses the actual release ZIP and verifies both bundled helpers. Install `ffmpeg-full` on the developer/CI machine for the HEVC fixture generator; runtime playback tests use the bundled helpers when `BEAMLY_TEST_APP_BUNDLE` is set. Tests generate their own small videos and use isolated playlists, settings, and installation directories. Apple Silicon builds run both helper CPU slices without Homebrew in PATH, using Rosetta 2 for Intel; Intel hosts inspect ARM linkage but execute only x86_64.

[GitHub Actions](.github/workflows/ci.yml) runs these checks for pull requests targeting `develop` or `main`, and for pushes to both branches. CI builds and verifies the application; publishing a release remains a separate maintainer action.

See [release instructions](Docs/RELEASING.md) and the [media HTTP contract](Docs/Media-HTTP.md). The icon's [PNG source](Resources/AppIcon.png) and [imagegen prompt](Resources/AppIcon.prompt.txt) are included; `swift Scripts/make-icon.swift Resources/AppIcon.icns` repacks its macOS sizes.

## Privacy and limitations

- Videos stay on your Mac and are streamed to your receiver. There is no cloud upload or telemetry.
- The local media server uses temporary, random capability URLs over HTTP. Anyone who obtains a complete URL can access that stream until playback is revoked. Use a trusted local network; do not expose the media port to the internet.
- Compatible video is preserved, including 4K HEVC and HDR10/HLG, with separate audio and text subtitles. Explicit compatibility conversion uses H.264 up to 1080p, stereo AAC, HDR-to-SDR tone mapping, and subtitle burn-in. Dolby Vision remuxing and bitmap subtitles require the paths described in [video quality and AirPlay](Docs/Media-Streaming.md).
- Converted segments remain on disk until playback stops. Long movies need free disk space; encoding stops if less than 256 MiB remains. A crash can leave temporary files for macOS to clean up.
- The queue is stored at `~/Library/Application Support/Peamer/playlist.json`. The legacy directory and bundle identifier `app.peamer.mac` are retained so existing users keep their data. Removing the app or a queue entry does not remove original videos.
- Physical receiver compatibility, older macOS versions, Intel hardware, bitmap subtitles on real media, and network changes during playback need broader testing. Intel is cross-compiled; local runtime validation was on Apple Silicon.
- Manual update checks contact GitHub for release metadata and assets. Automatic background checks, downloads, and system profiling are disabled.
- AirPlay discovery, selection, and authorization are handled by AVKit. Legacy standalone AirPlay pairing, Chromecast, and DRM-protected streaming services are outside the current scope.

## Contributing and license

Bug reports and focused pull requests are welcome. Include your macOS version, Mac architecture, receiver model, and a small reproducible example. Do not include private videos or complete media URLs in public reports. See [CONTRIBUTING.md](CONTRIBUTING.md).

Beamly's own source code, documentation, and original icon are available under the [MIT license](LICENSE). The bundled Sparkle framework retains its [upstream license notices](Resources/Sparkle.LICENSE). Beamly includes separate GPLv2 FFmpeg/FFprobe executables with corresponding source and their libraries' [license notices](Docs/Bundled-media.md); no FFmpeg libraries are linked into Beamly's application. Beamly is an independent project; it is not affiliated with Apple or Beamer and includes no proprietary Beamer code or assets.
