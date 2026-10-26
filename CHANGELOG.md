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

**This community build is ad-hoc signed and is not notarized by Apple.** macOS may block its first launch; see the [first-launch instructions](https://github.com/StPashik/Beamly#first-launch). FFmpeg is installed separately, or automatically by the Homebrew cask. The application UI is currently in Russian.

## Known limitations

Transcoding is limited to H.264 up to 1080p with stereo AAC, and its temporary buffer grows until playback stops. No Chromecast, legacy standalone AirPlay pairing, DRM streaming, or automatic updates. Intel is cross-compiled; broader testing on Intel, macOS 14–15, and different physical receivers is still needed.
