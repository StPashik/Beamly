# Video quality and AirPlay

Beamly uses AVPlayer and the system AirPlay picker. The quality-preserving path targets Apple TV 4K. Receiver generations, tvOS versions, display capabilities, and network bandwidth still affect playback. A 4K output mode on the television does not by itself prove that its input stream is 4K.

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations.**

## Playback paths

With **Preserve video quality** enabled (the default), compatible MP4/M4V/MOV files are published unchanged. For supported HEVC or H.264 in MKV and other containers, FFmpeg copies the compressed video into HLS fragmented MP4 segments. No video encoder, resizing, color conversion, or subtitle filter runs in this path. The interface reports **Original video quality**; the metadata row describes the source file.

The remux path accepts HEVC Main/Main 10, 4:2:0, up to Level 5.1, 4096 × 2160, and 60 fps for SDR / 30 fps for HDR. HDR10 (PQ) and HLG retain their original bit depth, color characteristics, and in-bitstream metadata. The multivariant playlist declares `hvc1`, resolution, frame rate, and `VIDEO-RANGE`. HDR10+ dynamic metadata and Dolby Vision are not certified by this implementation. Dolby Vision remuxing is rejected explicitly rather than silently losing or mislabeling its metadata; compatible Dolby Vision MP4 files can still use direct playback.

The qualified codec string comes from the actual initialization segment's `hvcC`/`avcC` record through CoreMedia, rather than FFmpeg's generated master-playlist text. Segment sizes determine advertised bitrates.

Turning off **Preserve video quality** explicitly selects H.264 up to 1080p and stereo AAC. HDR10/HLG is tone-mapped to BT.709 SDR before subtitle burn-in and scaling. Unsupported SDR codecs also use this compatibility conversion. Unsupported HEVC/HDR profiles and bitmap subtitles do not silently trigger a quality downgrade while preservation is enabled.

## Audio

The app's audio menu chooses the source track by its global stream index. Stereo AAC-LC is copied. Other audio gets a stereo AAC rendition. AC-3/E-AC-3 surround tracks also get an unmodified surround rendition, with a separate audio group and an AAC fallback. The video rendition is shared. DTS/TrueHD/Atmos conversion or passthrough is not promised; conversion of unsupported audio is independent of video and does not reduce its resolution.

Changing the source audio track rebuilds the HLS publication at the current movie position and preserves paused/playing state. Original video and audio files are never modified.

**Settings → Track preferences** stores independent audio and subtitle choices. Language codes from stream metadata are normalized using Foundation, including two- and three-letter ISO codes and regional tags. A matching non-commentary audio track is preferred, with the default track winning ties. **Original audio** uses FFmpeg's `original` disposition or AVFoundation's `isOriginalContent` characteristic; without that marker, or if a requested language is absent, Beamly uses the file's default audio. Settings apply only when a video is opened, so manual choices survive seeks and stream rebuilds. Queue transitions and relaunches use the saved preferences.

## Subtitles

Selected embedded text subtitles and external SRT/ASS/SSA/WebVTT are converted to a separate WebVTT rendition. Each WebVTT file includes `X-TIMESTAMP-MAP`; cues spanning a seek point are retained and clipped at the new stream origin. Subtitles do not force video encoding. ASS animation, fonts, and complex positioning are simplified by WebVTT conversion. Bitmap formats such as PGS/VobSub require the explicit compatibility conversion and burn-in.

Text extraction reads the subtitle source before publishing the selected rendition. For embedded subtitles this can require scanning the movie; large files and slow storage increase preparation time. Subtitle intermediates stay under `.inputs` and are not served. The selected caption track is explicitly enabled in AVPlayer, independently of system caption preferences.

When selecting a video, Beamly scans only its containing folder for readable SRT, ASS, SSA, and VTT files. Names must match the video basename exactly or append a dot-separated suffix, such as `Movie.ru.srt`; similarly prefixed movies do not match. An exact-basename file takes priority, and a single match is selected automatically. Multiple language files remain available in the subtitle menu without guessing a preferred language.

That behavior is the default **Automatic** subtitle preference. **Off** prevents automatic caption selection. A specific language matches embedded metadata or the first sidecar suffix, such as `Movie.ru.srt`, `Movie.rus.srt`, or `Movie.ru-RU.srt`; a plain `Movie.srt` has no inferred language. Full captions take priority over tracks marked forced-only, and matching sidecars take priority over embedded captions of the same kind. A missing language leaves captions off. Bitmap captions are not automatically selected while **Preserve video quality** is enabled.

AVFoundation can expose both full and forced-only views of the same MOV/MP4 text track. The source-track menu uses full views when available, retaining the source's forced/default flags and stream IDs, so these generated views do not become nonexistent FFmpeg streams when timing changes require HLS.

**Subtitle timing…** adjusts the selected captions in 0.5-second steps. Positive values show captions later, negative values earlier. WebVTT cue times are shifted relative to the measured HLS origin; compatibility rendering changes only the subtitle clock and restores the video clock afterward. Embedded captions requiring a correction use HLS instead of direct MP4 playback and retain the same profile restrictions. Bitmap caption shifts use FFmpeg's subtitle-video timestamp adjustment before overlay. Corrections survive seeking and track changes and are stored with the movie's queue entry. Existing queues without a correction retain zero offset; removing an entry removes its correction. Source files are never modified.

## Seeking and buffering

Remuxing starts at a preceding demuxer keyframe. FFmpeg reads preroll with original timestamps; a packet filter with `amount=0` discards only pictures before that random-access point, including leading open-GOP pictures that depend on an earlier GOP. Compressed payloads of retained pictures are untouched. Beamly measures the first output video timestamp and maps the generated timeline back to the original movie, including B-frame delay. Initial resume, track changes, and seeks outside the published range prepare a new stream and seek to the requested position within its initial GOP. Seeking within the published range uses AVPlayer directly.

Generated media uses growing EVENT playlists and becomes complete when FFmpeg finishes. The master advertises measured segment bitrates and is refreshed after generation completes. This is a local on-demand stream with one source video quality, not an adaptive internet streaming ladder. Native Apple TV scrubbing is limited to the currently published timeline; dedicated I-frame trick-play renditions are not supplied. Generated media remains on disk until playback stops, with the existing free-space guard.

The playback status reports actual preparation stages: inspecting the file, preparing original-quality segments or compatibility video, preparing captions, and loading the AVPlayer item. A failed system-encoder attempt reports its retry with the software encoder; the quality explanation retains that reason after loading. VideoToolbox is described as the system encoder because its current `allow_sw` setting permits an internal software implementation. No hardware-use guarantee, percentage, or ETA is inferred from the selected setting.

During playback, Beamly observes both AVPlayer's `timeControlStatus` and `reasonForWaitingToPlay`. It reports **Buffering…** only for `waitingToPlayAtSpecifiedRate` with `toMinimizeStalls`; the initial `evaluatingBufferingRate` phase is distinguished from a stall. This identifies the player's waiting state, without attributing it to Wi-Fi or conversion speed. Pause remains available while waiting, and disconnecting AirPlay still pauses playback. Cancellation and new-file selection clear preparation, quality, and retry messages; callbacks from an older load are ignored.

## Chapters and seek previews

FFprobe reads chapter titles and start/end times from the original file. Invalid and nonfinite ranges are ignored, valid ends are limited to the movie duration, and chapters are shown in source-time order. Playable MP4/MOV files retain a native AVFoundation chapter-loading fallback when FFprobe cannot inspect them, including chapters without a language tag. Files without chapters are not given synthetic ones.

The chapter menu uses the same seek path as the timeline, including rebuilding HLS when a chapter lies before or outside the current buffer. Chapter names and the active chapter come from the original movie's timeline rather than the temporary HLS segment clock. Track choices and subtitle timing remain attached to the current movie.

Timeline hover and drag previews use still images from the original file through AVAssetImageGenerator, with the bundled FFmpeg fallback. Frames are limited to 288 × 162 pixels, requested at one-second intervals after a short debounce, and held in a small transient per-video cache. Leaving the timeline, cancelling preparation, switching files, or stopping cancels obsolete requests. A failed preview does not interrupt playback. The midpoint image remains static; hovering does not seek, start playback, or change the saved resume position.

Video-only fMP4 streams use an explicit initialization filename: FFmpeg does not expand the variant placeholder for a single variant. Audio-bearing streams retain their existing per-variant initialization files.

## Verification

Automated checks use generated media, never personal movies:

- 3840 × 2160, 10-bit HEVC with PQ, BT.2020, mastering-display metadata, and content-light metadata;
- exact hashes of every decoded frame before and after remuxing;
- separate surround/stereo audio renditions and source-track selection;
- native AVPlayer loading, decoding, saved-position resume, forward/backward seeks, and caption selection;
- embedded/external text subtitles, overlapping cues, and timeline offsets;
- actual HTTP fetching of the master, media playlists, initialization segments, fragments, and captions;
- cancellation, existing MP4 playback, and queue/file preservation.
- generated MP4/MKV chapters, chapter seeks across HLS buffer rebuilds, still-frame timestamps, and thumbnail cancellation without moving the player.

These checks do not certify physical AirPlay output, HDR display activation, every Dolby profile, Wi-Fi performance, or every receiver. Validate those on an Apple TV 4K and an HDR-capable display before describing hardware compatibility as confirmed.

The native 4K frame test uses HDR only when AVPlayer reports HDR eligibility, otherwise 4K SDR. HDR10/HLG metadata and decoded-frame preservation are always checked by FFmpeg. `BEAMLY_TEST_TOOLS_DIRECTORY=/absolute/path/to/tools Scripts/test.sh` runs the 4K fixtures against an isolated FFmpeg/ffprobe installation without replacing system tools.

## References

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
