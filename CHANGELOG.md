# Beamly 1.0.1

Beamly 1.0.1 adds signed in-app updates and five interface languages.

- Choose **English, Russian, German, French, or Spanish** in **Beamly → Settings → Language**, then restart. English is the default.
- Use **Beamly → Check for Updates…** or **Settings → Updates** to check, download, and install a new version. Sparkle verifies the signed feed and archive. Automatic checks, background installs, and system profiling are disabled.
- Homebrew's subtitle-capable **ffmpeg-full** is detected automatically, including its keg-only installation.
- Playback waits for the saved-position seek to finish before recording progress, preventing a race that could overwrite the resume position with zero.
- GitHub Actions now runs the Swift tests, universal build, localization packaging checks, and npm installer tests on main and develop.

Download **Beamly-1.0.1-universal.zip**, extract it, and move Beamly.app to Applications. Verify the download using SHA256SUMS. Homebrew and npm installation instructions are in the [README](https://github.com/StPashik/Beamly#install).

**Upgrading from 1.0.0:** install 1.0.1 manually, with Homebrew, or with the npm installer once. Version 1.0.0 does not contain the updater. Your existing queue and settings are preserved.

Requires macOS 14 or later. The app is universal for Apple Silicon and Intel; FFmpeg is installed separately.

**This community build is ad-hoc signed and is not notarized by Apple.** Sparkle's update signatures authenticate updates but do not replace Apple notarization. See [first-launch instructions](https://github.com/StPashik/Beamly#first-launch). Physical receivers, Intel runtime behavior, and older supported macOS versions need broader testing.

---

# Beamly 1.0.0

First public open-source release, under the MIT license.

- Native macOS AirPlay player with a compact translucent interface and Liquid Glass panels on macOS 26+.
- Universal application for Apple Silicon and Intel, requiring macOS 14 or later.
- Direct MP4/MOV playback and FFmpeg-based conversion for other local video formats.
- Audio tracks, embedded and external subtitles, saved queue positions, shuffle, repeat, and Delete-key removal from the queue.
- Original glass-style app icon.
- Homebrew cask and a dependency-free npm installer that downloads and verifies the native app.

## Install

Download and extract `Beamly-1.0.0-universal.zip`, then move `Beamly.app` to Applications. `SHA256SUMS` verifies the download. Installation through Homebrew and npm is documented in the [README](https://github.com/StPashik/Beamly#install).

**This community build is ad-hoc signed and is not notarized by Apple.** macOS may block its first launch; see the [first-launch instructions](https://github.com/StPashik/Beamly#first-launch). Install FFmpeg separately for conversion and external subtitles. The application UI is currently in Russian.

## Known limitations

Transcoding is limited to H.264 up to 1080p with stereo AAC, and its temporary buffer grows until playback stops. No Chromecast, legacy standalone AirPlay pairing, DRM streaming, or automatic updates. Intel is cross-compiled; broader testing on Intel, macOS 14–15, and different physical receivers is still needed.
