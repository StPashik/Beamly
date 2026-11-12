# Video quality and AirPlay

Beamly uses AVPlayer and the system AirPlay picker. The quality-preserving path targets Apple TV 4K. Receiver generations, tvOS versions, display capabilities, and network bandwidth still affect playback. A 4K output mode on the television does not by itself prove that its input stream is 4K.

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations.**

## Playback paths

With **Preserve video quality** enabled (the default), compatible MP4/M4V/MOV files are published unchanged. For supported HEVC or H.264 files that use HLS, FFmpeg copies the compressed video into fragmented MP4 segments. No video encoder, resizing, color conversion, or subtitle filter runs in this path. The interface reports **Original video quality**; the metadata row describes the source file.

For supported H.264 MKV files with a selected Dolby Digital or Dolby Digital Plus surround track, Beamly can prepare a temporary MP4 when the file has no embedded text captions or compatible alternate audio, subtitles are off, and audio timing is unadjusted. FFmpeg copies the video and selected audio. The MP4 index gives AVPlayer the full movie and the saved position is applied as a seek. If the MP4 cannot be prepared or played, Beamly uses HLS.

The remux path accepts HEVC Main/Main 10, 4:2:0, up to Level 5.1, 4096 × 2160, and 60 fps for SDR / 30 fps for HDR. HDR10 (PQ) and HLG retain their original bit depth, color characteristics, and in-bitstream metadata. The multivariant playlist declares `hvc1`, resolution, frame rate, and `VIDEO-RANGE`. HDR10+ dynamic metadata and Dolby Vision are not certified by this implementation. Dolby Vision remuxing is rejected explicitly rather than silently losing or mislabeling its metadata; compatible Dolby Vision MP4 files can still use direct playback.

The qualified codec string comes from the actual initialization segment's `hvcC`/`avcC` record through CoreMedia, rather than FFmpeg's generated master-playlist text. Segment sizes determine advertised bitrates.

Turning off **Preserve video quality** explicitly selects H.264 up to 1080p and stereo AAC. HDR10/HLG is tone-mapped to BT.709 SDR before subtitle burn-in and scaling. Unsupported SDR codecs also use this compatibility conversion. Unsupported HEVC/HDR profiles and bitmap subtitles do not silently trigger a quality downgrade while preservation is enabled.

## Audio

The app's audio menu chooses the source track by its global stream index. Original-quality HLS copies multichannel AC-3/E-AC-3 and publishes compatible alternate tracks in the same audio group. Tracks in the group have matching codecs, channel counts, and durations. Beamly reads the E-AC-3 initialization segment to signal Dolby Atmos when its JOC extension is present. If AVPlayer reports a Dolby playback error, Beamly retries once with the selected track in stereo AAC at the same movie position and keeps the selected captions. Apple specifies stereo AAC for general HLS delivery. The fast path targets receivers that support Dolby audio.

Beamly copies compatible AAC-LC and converts other formats to stereo AAC. When conversion is needed in original-quality HLS, FFmpeg tries AudioToolbox first and then its built-in AAC encoder if AudioToolbox fails. DTS/TrueHD/Atmos conversion or passthrough is not promised. Audio conversion is independent of video and preserves its resolution.

Apple TV and Beamly can switch tracks in the current HLS audio group during playback. Choose a track with a different format in Beamly's audio menu to prepare a new stream at the current position. Source files are read in place.

**Settings → Track preferences** stores independent audio and subtitle choices. Language codes from stream metadata are normalized using Foundation, including two- and three-letter ISO codes and regional tags. A matching non-commentary audio track is preferred, with the default track winning ties. **Original audio** uses FFmpeg's `original` disposition or AVFoundation's `isOriginalContent` characteristic; without that marker, or if a requested language is absent, Beamly uses the file's default audio. Settings apply only when a video is opened, so manual choices survive seeks and stream rebuilds. Queue transitions and relaunches use the saved preferences.

**Audio timing…** in the speaker menu stores a per-video correction from −10 to +10 seconds in 0.1-second steps. Positive values delay audio. A corrected MP4 uses HLS instead of direct playback. The original-quality path reads audio from a second input with FFmpeg's `-itsoffset`, leaving video packets and HDR metadata unchanged; audio preroll and packet trimming use the shifted timestamps. Stereo AAC and AC-3/E-AC-3 surround retain their existing copy paths. Compatibility conversion seeks the audio input independently, retaining the movie and subtitle clocks. Hardware-to-software retry forwards the correction. This controls a fixed offset; actual receiver latency still needs physical calibration.

## Subtitles

Original-quality HLS includes each readable embedded text subtitle track and any selected external SRT/ASS/SSA/WebVTT file as separate named WebVTT renditions. Apple TV can switch among these tracks or turn captions off during playback. Each WebVTT file includes `X-TIMESTAMP-MAP`, keeping captions available across the full timeline. Video packets are copied. WebVTT simplifies ASS animation, fonts, and complex positioning. Bitmap formats such as PGS/VobSub require the explicit compatibility conversion and burn-in.

Beamly extracts embedded text tracks in one pass before publishing the HLS stream. Subtitle intermediates stay in the private `.inputs` directory. Beamly sets the initial caption selection in AVPlayer using the app's preferences.

When selecting a video, Beamly scans only its containing folder for readable SRT, ASS, SSA, and VTT files. Names must match the video basename exactly or append a dot-separated suffix, such as `Movie.ru.srt`; similarly prefixed movies do not match. An exact-basename file takes priority, and a single match is selected automatically. Multiple language files remain available in the subtitle menu without guessing a preferred language.

That behavior is the default **Automatic** subtitle preference. **Off** prevents automatic caption selection. A specific language matches embedded metadata or the first sidecar suffix, such as `Movie.ru.srt`, `Movie.rus.srt`, or `Movie.ru-RU.srt`; a plain `Movie.srt` has no inferred language. Full captions take priority over tracks marked forced-only, and matching sidecars take priority over embedded captions of the same kind. A missing language leaves captions off. Bitmap captions are not automatically selected while **Preserve video quality** is enabled.

AVFoundation can expose both full and forced-only views of the same MOV/MP4 text track. The source-track menu uses full views when available, retaining the source's forced/default flags and stream IDs, so these generated views do not become nonexistent FFmpeg streams when timing changes require HLS.

**Subtitle timing…** adjusts the selected captions in 0.5-second steps. Positive values show captions later, negative values earlier. WebVTT cue times are shifted relative to the measured HLS origin; compatibility rendering changes only the subtitle clock and restores the video clock afterward. Embedded captions requiring a correction use HLS instead of direct MP4 playback and retain the same profile restrictions. Bitmap caption shifts use FFmpeg's subtitle-video timestamp adjustment before overlay. Corrections survive seeking and track changes and are stored with the movie's queue entry. Existing queues without a correction retain zero offset. Removing an entry keeps its correction in local watch history until that history entry is forgotten or evicted. Source files are never modified.

## Seeking and buffering

Beamly prepares HLS from the beginning of the movie. Resume and track changes seek to the saved position in AVPlayer after loading the full stream, keeping earlier segments available for receiver controls. Regular seeks use the current item. For copied video, FFmpeg starts at a safe keyframe, and Beamly measures the muxer's timestamp shift to preserve the movie clock, including B-frame delay. Compressed video packets are untouched.

Beamly publishes the EVENT playlists only after FFmpeg has finished and all media renditions contain `EXT-X-ENDLIST`. The master advertises measured segment bitrates. This gives the receiver a finite timeline from the first request. Receiver seeks use the regular media renditions. Preparing the full movie takes more time and temporary space, especially in compatibility mode. Cancelling preparation or stopping playback clears the generated media.

The playback status reports actual preparation stages: inspecting the file, preparing original-quality segments or compatibility video, preparing captions, and loading the AVPlayer item. During packaging, the percentage estimates processed media from FFmpeg's reported timestamps and frame count. A failed system-encoder attempt reports its retry with the software encoder; the quality explanation retains that reason after loading. VideoToolbox's `allow_sw` setting permits an internal software implementation, so the stage does not guarantee hardware use.

During playback, Beamly observes both AVPlayer's `timeControlStatus` and `reasonForWaitingToPlay`. It reports **Buffering…** only for `waitingToPlayAtSpecifiedRate` with `toMinimizeStalls`; the initial `evaluatingBufferingRate` phase is distinguished from a stall. This identifies the player's waiting state, without attributing it to Wi-Fi or conversion speed. Pause remains available while waiting, and disconnecting AirPlay still pauses playback. Cancellation and new-file selection clear preparation, quality, and retry messages; callbacks from an older load are ignored.

During an item replacement, the retained AVPlayer keeps its paused current item and the old stream available until the new item is ready and its source position has been restored. This avoids clearing the selected AirPlay route between audio/subtitle changes, seeks, and queue transitions. Superseded preparation is cancelled; Stop and shutdown also revoke the retained stream.

When no receiver is known, a manual Play request opens the native AirPlay picker while the movie is preparing. If a route may already be selected, Beamly primes the ready player at rate zero for up to three seconds before asking again. `AVPlayer.isExternalPlaybackActive` must confirm the external route before Beamly calls `play()`. Genuine disconnection during playback pauses and clears play intent. A temporary route transition during preparation retains that intent.

## Chapters and seek previews

FFprobe reads chapter titles and start/end times from the original file. Invalid and nonfinite ranges are ignored, valid ends are limited to the movie duration, and chapters are shown in source-time order. Playable MP4/MOV files retain a native AVFoundation chapter-loading fallback when FFprobe cannot inspect them, including chapters without a language tag. Files without chapters are not given synthetic ones.

The chapter menu uses the same seek path as the timeline. Chapter names and the active chapter come from the original movie's timeline. Track choices and subtitle timing remain attached to the current movie.

Timeline hover and drag previews use still images from the original file through AVAssetImageGenerator, with the bundled FFmpeg fallback. Frames are limited to 288 × 162 pixels, requested at one-second intervals after a short debounce, and held in a small transient per-video cache. Leaving the timeline, cancelling preparation, switching files, or stopping cancels obsolete requests. A failed preview does not interrupt playback. The midpoint image remains static; hovering does not seek, start playback, or change the saved resume position.

Video-only fMP4 streams use an explicit initialization filename: FFmpeg does not expand the variant placeholder for a single variant. Audio-bearing streams retain their existing per-variant initialization files.

## Sleep timer

The player and Playback menu offer a cancellable timer for the whole queue. The deadline uses Swift's ContinuousClock so changing the wall clock does not extend it, and system suspension counts toward the interval. Remaining time refreshes while the app runs; if execution is suspended beyond the deadline, expiry is applied on resume. A new duration replaces the old deadline, and timers are not persisted across launches.

Expiry saves the current source position and uses the existing playback cancellation path to stop HLS work, revoke the stream, and reject stale preparation/end callbacks. It does not call the manual Stop action, which resets the position. Pausing, seeking, changing tracks, and selecting another queue entry preserve the timer. Manual Stop, an empty queue, and shutdown cancel it.

## Watch history and menu bar remote

Watch history is an optional, bounded list in the existing atomically written playlist JSON; old queues seed it from valid resume positions. It keeps source URLs, positions, durations, timing corrections, and last-viewed dates on this Mac. Queue removal and clearing preserve it. Re-adding a known URL restores its values without reusing the old queue UUID. Completed entries restart through the existing near-end resume rule. Clearing history preserves the current queue and is not undone by an unchanged paused session at shutdown; subsequent viewing or timing changes can record the movie again. The limit is 100 videos, keyed by standardized file URL; renamed or moved files need to be added again.

History reuses the main window's compact custom controls, fixed width, translucent background, adaptive accent, and GlassSurface panels, including the reduced-transparency fallback.

The native SwiftUI `MenuBarExtra` shares the app's retained `AppModel` and `AVPlayer`. Closing the last window no longer quits; the mini remote can reopen the main window or explicitly quit. Play without an external route reopens the main window for its existing native AirPlay picker. Volume is controlled on the receiver; the mini remote offers playback, skips, queue navigation, and the sleep timer. Manual Stop remains in the Playback menu. No second player, global keyboard hooks, or local-network control API is introduced.

## Verification

Automated checks use generated media, never personal movies:

- 3840 × 2160, 10-bit HEVC with PQ, BT.2020, mastering-display metadata, and content-light metadata;
- exact hashes of every decoded frame before and after remuxing;
- original surround audio, stereo retry, and audio selection within the same stream;
- native AVPlayer loading, decoding, resume with the full duration, receiver-style seeks back to the beginning, and caption selection;
- embedded/external text subtitles, overlapping cues, and timeline offsets;
- actual HTTP fetching of the master, media playlists, initialization segments, fragments, and captions;
- cancellation, existing MP4 playback, and queue/file preservation.
- generated MP4/MKV chapters, chapter seeks, still-frame timestamps, and thumbnail cancellation without moving the player.
- timer replacement/cancellation, expiry during HLS playback and preparation, saved-position restoration, and rejection of late queue-advance callbacks.
- signed audio corrections with AAC and surround, original 4K frame/HDR metadata preservation, caption clocks, conversion, source-duration bounds, and seeks beyond shifted audio.
- history migration, completed-video restart, queue removal/re-addition, persisted history clearing, and shared mini-remote controls/window lifecycle.

Physical Apple TV 4K trials used a 1080p MKV with Dolby Digital Plus. They verified opening the AirPlay picker during preparation, resuming with sound, and seeking back to the beginning with the receiver remote. Dolby HLS trials verified switching audio languages and changing or turning off subtitles with the remote. Hardware validation of 4K/HDR and Atmos speaker output remains pending.

The native 4K frame test uses HDR only when AVPlayer reports HDR eligibility, otherwise 4K SDR. HDR10/HLG metadata and decoded-frame preservation are always checked by FFmpeg. `BEAMLY_TEST_TOOLS_DIRECTORY=/absolute/path/to/tools Scripts/test.sh` runs the 4K fixtures against an isolated FFmpeg/ffprobe installation without replacing system tools.

## References

- [Apple external playback state](https://developer.apple.com/documentation/avfoundation/avplayer/isexternalplaybackactive): active playback rather than stored device selection.
- [Apple player preroll](https://developer.apple.com/documentation/avfoundation/avplayer/preroll(atrate:completionhandler:)): preparing a ready player while its rate is zero.

- [Apple menu bar extras](https://developer.apple.com/documentation/swiftui/menubarextra): native menu bar scenes sharing the app model.
- [FFmpeg input options](https://ffmpeg.org/ffmpeg.html#Main-options): per-input seeking and timestamp offsets.

- [Swift continuous clock](https://developer.apple.com/documentation/swift/clock/continuous): elapsed time that includes system suspension.
- [Apple chapter metadata loading](https://developer.apple.com/documentation/avfoundation/avasset/loadchaptermetadatagroups(bestmatchingpreferredlanguages:completionhandler:)): chapter titles and source time ranges.
- [Apple image generation](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image(at:)): still frames without using the playback player.
- [Apple AVPlayer waiting reasons](https://developer.apple.com/documentation/avfoundation/avplayer/reasonforwaitingtoplay): distinguishing buffer evaluation from waiting to avoid stalls.
- [Apple HLS authoring specification](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html): video 1.5–1.10, HDR frame rate amendment for tvOS, audio groups, WebVTT timestamp mapping, manifests, and validation tools.
- [FFmpeg streamcopy](https://ffmpeg.org/ffmpeg.html#Streamcopy): copying compressed packets without decoding or encoding.
- [FFmpeg HLS muxer](https://ffmpeg.org/ffmpeg-formats.html#hls-2): fragmented MP4, variant playlists, and event playlists.
- [FFmpeg filters](https://ffmpeg.org/ffmpeg-filters.html#tonemap): explicit HDR-to-SDR compatibility conversion.
- [FFmpeg advanced options](https://ffmpeg.org/ffmpeg.html#Advanced-options): bitmap subtitle timestamp shifting before overlay.
- [FFmpeg packet filtering](https://www.ffmpeg.org/ffmpeg-bitstream-filters.html#noise): timestamp-based preroll removal with payload modification disabled.
- [ETSI TS 103 285](https://www.etsi.org/deliver/etsi_ts/103200_103299/103285/01.01.01_60/ts_103285v010101p.pdf): HEVC codec-string fields and compatibility/constraint bit representation.
