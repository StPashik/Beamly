# Unreleased

- Add local watch history and Continue watching, retaining resume positions and timing corrections after queue removal.
- Add per-video audio timing in 0.1-second steps, preserving original video/HDR during HLS remuxing and keeping seeks and subtitles on the source clock.
- Add a native menu bar mini remote; closing the main window keeps playback available until Beamly is explicitly quit.
- Add a sleep timer that stops playback and retains the resume position.
- Translate the new controls into all five interface languages.

---

# Beamly 1.0.8

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations.**

Beamly adds chapter navigation and still-frame previews above the playback timeline.

- Choose embedded chapters from the chapter icon beside the timeline or **Playback → Chapters**. Show the current chapter, retain source titles, and number unnamed chapters. Files without chapters keep the menu disabled.
- Hover over the timeline or drag its handle to see a source frame, time, and chapter title. Hovering keeps playback and saved positions unchanged; dragging seeks on release and preserves the paused or playing state. The main midpoint image stays static.
- Match preview time to the native slider's thumb bounds, including the ends of long videos. Reuse native image generation and the bundled FFmpeg fallback, with cancellation, debounce, and a small per-video memory cache.
- Keep chapter timestamps aligned with the original movie through direct playback and HLS buffer rebuilds. Retain native MP4/MOV chapter loading when probing fails, including chapters without a language tag. Ignore invalid chapter ranges and obsolete thumbnail results.
- Fix the initialization filename for video-only HLS fragmented MP4. Translate chapter controls and preview messages into all five interface languages.

**Update:** choose **Beamly → Check for Updates…** or **Settings → Updates**. Your queue, timing corrections, and preferences are preserved. FFmpeg and FFprobe remain included for Apple Silicon and Intel.

Dolby Vision remuxing is not supported. Bitmap subtitles require compatibility conversion; ASS styling is simplified. See [video quality and AirPlay](Docs/Media-Streaming.md) for supported profiles and verification limits.

**This community build is ad-hoc signed and is not notarized by Apple.** Requires macOS 14 or later on Apple Silicon or Intel.

---

# Beamly 1.0.7

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations.**

Beamly shows what is happening while a video prepares and plays, with clear quality and conversion explanations beside the preview.

- Show preparation stages for reading video information, original-video streaming, system or software encoding, subtitles, and player loading. Show software-encoder retries when system conversion fails.
- Distinguish starting playback from buffering reported by AVPlayer. Keep Pause available while playback waits, and show when an AirPlay device must be selected.
- Identify video preserved without conversion and compatibility conversion up to 1080p SDR. Explain whether conversion is required by the format or the quality setting, and when software encoding is in use.
- Clear outdated status when switching videos, stopping, or cancelling preparation. Keep full status and quality explanations available on hover, with translations in all five interface languages.

**Update:** choose **Beamly → Check for Updates…** or **Settings → Updates**. Your queue, timing corrections, and preferences are preserved. FFmpeg and FFprobe remain included for Apple Silicon and Intel.

These statuses describe the preparation path and AVPlayer state; they do not certify the receiver's actual resolution or HDR output. Dolby Vision remuxing is not supported. Bitmap subtitles require compatibility conversion; ASS styling is simplified. See [video quality and AirPlay](Docs/Media-Streaming.md) for supported profiles and verification limits.

**This community build is ad-hoc signed and is not notarized by Apple.** Requires macOS 14 or later on Apple Silicon or Intel.

---

# Beamly 1.0.6

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations.**

Beamly remembers your preferred audio and subtitle languages and applies them when each video opens.

- Choose independent audio and subtitle preferences in **Settings → Track preferences**, including file-default or explicitly marked original audio, preferred languages, automatic subtitles, and subtitles off. Settings survive relaunches and apply to subsequent queue entries.
- Match embedded language metadata and adjacent subtitle filenames, including two- and three-letter ISO codes and regional tags. Prefer full captions over forced-only captions. Missing preferred audio falls back to the file's default track; missing preferred subtitles stay off.
- Keep manual track choices while seeking or changing subtitle timing. Honor the file's default audio in direct and HLS playback.
- Keep AVFoundation's generated forced-only subtitle views mapped to physical source streams, preserving track selection when timing corrections switch playback to HLS.
- Include preference labels and help in all five interface languages. Original audio requires a marker in the file; Beamly does not guess the original language.

**Update:** choose **Beamly → Check for Updates…** or **Settings → Updates**. Your queue, timing corrections, and preferences are preserved. FFmpeg and FFprobe remain included for Apple Silicon and Intel.

Dolby Vision remuxing is not supported. Bitmap subtitles require compatibility conversion; ASS styling is simplified. See [video quality and AirPlay](Docs/Media-Streaming.md) for supported profiles and verification limits.

**This community build is ad-hoc signed and is not notarized by Apple.** Requires macOS 14 or later on Apple Silicon or Intel.

---

# Beamly 1.0.5

Beamly finds matching subtitle files beside your videos and remembers each movie's timing correction.

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations.**

- Find adjacent SRT, ASS, SSA, and VTT files matching the video's basename, including language suffixes such as `Movie.ru.srt`. Select an exact-basename match or the only match automatically; list other matches in the subtitle menu.
- Adjust subtitle timing in 0.5-second steps and reset it from a dedicated popover. Keep each movie's correction with its saved queue entry, including across relaunches.
- Apply timing to separate WebVTT captions and compatibility subtitle rendering without shifting the video or audio. Preserve corrections across seeks and track changes.

**Update:** choose **Beamly → Check for Updates…** or **Settings → Updates**. Your queue and preferences are preserved; existing queue files remain compatible. FFmpeg and FFprobe are included.

**This community build is ad-hoc signed and is not notarized by Apple.** Requires macOS 14 or later on Apple Silicon or Intel.

---

# Beamly 1.0.4

Beamly now includes FFmpeg and FFprobe for MKV streaming, external subtitles, and compatibility conversion without a separate installation.

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations.**

- Include standalone universal FFmpeg/FFprobe so MKV playback, external subtitles, and compatibility conversion work without a separate Homebrew installation.
- Preserve the existing 4K HEVC remux, HDR-to-SDR, libass subtitle, and software/hardware H.264 paths. Retain custom tool-folder overrides.
- Build pinned upstream sources, include component notices, and package complete corresponding GPLv2 media source beside application archives. Beamly's own code remains MIT licensed.
- Verify signed arm64/x86_64 helpers without Homebrew in PATH; run media integration tests against the bundled tools.

**Update:** choose **Beamly → Check for Updates…** or **Settings → Updates**. The universal app includes FFmpeg/FFprobe and their notices; the matching release also contains complete corresponding media source. Requires macOS 14 or later.

**This community build is ad-hoc signed and is not notarized by Apple.** Your queue and preferences are preserved.

---

# Beamly 1.0.3

Beamly 1.0.3 adds quality-preserving 4K HEVC/MKV streaming and supported HDR10/HLG signaling.

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some Apple TV, television, or network configurations.** Automated media and AVPlayer checks do not replace hardware testing.

- Preserve supported 4K HEVC/H.264 video in MKV by remuxing to HLS fragmented MP4, without video encoding or resizing.
- Preserve HDR10/HLG signaling and metadata; reject unsupported HEVC/HDR and Dolby Vision remuxing explicitly instead of silently reducing quality.
- Serve selected text subtitles as separate WebVTT, retaining cues across seeks. Bitmap subtitle burn-in remains available through explicit compatibility conversion.
- Copy stereo AAC-LC and AC-3/E-AC-3 surround where compatible; provide stereo AAC fallback independently of video.
- Map keyframe-aligned HLS timestamps back to the original movie for resume, seek, and track changes.
- Add explicit quality status, HDR-to-SDR compatibility conversion, five-language settings/help, and 4K media integration checks.

Dolby Vision remuxing is not supported. Bitmap subtitles require explicit compatibility conversion; ASS styling is simplified. See [video quality and AirPlay](Docs/Media-Streaming.md).

**Updating from 1.0.1 or 1.0.2:** use **Beamly → Check for Updates…** or **Settings → Updates**. The app preserves your queue and settings.

Download **Beamly-1.0.3-universal.zip**, extract it, and move Beamly.app to Applications. Requires macOS 14 or later on Apple Silicon or Intel; FFmpeg is installed separately.

**This community build is ad-hoc signed and is not notarized by Apple.** Update feeds and archives carry separate Sparkle signatures.

---

# Beamly 1.0.2

Beamly 1.0.2 makes the player more focused on AirPlay and simplifies device selection.

- **Fixed-width window:** the player stays 674 points wide. Resize its height or use the green button to zoom vertically.
- **Static video preview:** a frame from the middle of the source video replaces live local playback. MP4/MOV use AVFoundation; other formats have an FFmpeg fallback. Seeking does not change the preview.
- **AirPlay required:** all playback starts wait for a connected AirPlay receiver. Disconnecting pauses the player instead of continuing on the Mac.
- **Fewer clicks:** pressing Play without a connection opens the native AirPlay device picker directly, without an alert. Playback starts after the receiver connects.

**Updating from 1.0.1:** use **Beamly → Check for Updates…** or **Settings → Updates**. Your queue and settings are preserved. Users of 1.0.0 need one manual upgrade because that version has no updater.

Download **Beamly-1.0.2-universal.zip**, extract it, and move Beamly.app to Applications. SHA256SUMS verifies the download. Homebrew and npm installation instructions are in the [README](https://github.com/StPashik/Beamly#install).

Requires macOS 14 or later on Apple Silicon or Intel. FFmpeg is installed separately.

**This community build is ad-hoc signed and is not notarized by Apple.** Update feeds and archives carry separate Sparkle signatures. See [first-launch instructions](https://github.com/StPashik/Beamly#first-launch). Physical receivers, Intel runtime behavior, and older supported macOS versions need broader testing.

---

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
