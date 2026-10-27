# Video quality and AirPlay

Beamly uses AVPlayer and the system AirPlay picker. The quality-preserving path targets Apple TV 4K. Receiver generations, tvOS versions, display capabilities, and network bandwidth still affect playback. A 4K output mode on the television does not by itself prove that its input stream is 4K.

**4K/HDR over AirPlay has not been tested on physical receivers. Playback may be unstable or incompatible with some devices or network configurations.**

## Playback paths

With **Preserve video quality** enabled (the default), compatible MP4/M4V/MOV files are published unchanged. For supported HEVC or H.264 in MKV and other containers, FFmpeg copies the compressed video into HLS fragmented MP4 segments. No video encoder, resizing, color conversion, or subtitle filter runs in this path. The interface reports **Original video quality**; the metadata row describes the source file.

The remux path accepts HEVC Main/Main 10, 4:2:0, up to Level 5.1, 4096 × 2160, and 60 fps for SDR / 30 fps for HDR. HDR10 (PQ) and HLG retain their original bit depth, color characteristics, and in-bitstream metadata. The multivariant playlist declares `hvc1`, resolution, frame rate, and `VIDEO-RANGE`. HDR10+ dynamic metadata and Dolby Vision are not certified by this implementation. Dolby Vision remuxing is rejected explicitly rather than silently losing or mislabeling its metadata; compatible Dolby Vision MP4 files can still use direct playback.

Turning off **Preserve video quality** explicitly selects H.264 up to 1080p and stereo AAC. HDR10/HLG is tone-mapped to BT.709 SDR before subtitle burn-in and scaling. Unsupported SDR codecs also use this compatibility conversion. Unsupported HEVC/HDR profiles and bitmap subtitles do not silently trigger a quality downgrade while preservation is enabled.

## Audio

The app's audio menu chooses the source track by its global stream index. Stereo AAC-LC is copied. Other audio gets a stereo AAC rendition. AC-3/E-AC-3 surround tracks also get an unmodified surround rendition, with a separate audio group and an AAC fallback. The video rendition is shared. DTS/TrueHD/Atmos conversion or passthrough is not promised; conversion of unsupported audio is independent of video and does not reduce its resolution.

Changing the source audio track rebuilds the HLS publication at the current movie position and preserves paused/playing state. Original video and audio files are never modified.

## Subtitles

Selected embedded text subtitles and external SRT/ASS/SSA/WebVTT are converted to a separate WebVTT rendition. Each WebVTT file includes `X-TIMESTAMP-MAP`; cues spanning a seek point are retained and clipped at the new stream origin. Subtitles do not force video encoding. ASS animation, fonts, and complex positioning are simplified by WebVTT conversion. Bitmap formats such as PGS/VobSub require the explicit compatibility conversion and burn-in.

Text extraction reads the subtitle source before publishing the selected rendition. For embedded subtitles this can require scanning the movie; large files and slow storage increase preparation time. Subtitle intermediates stay under `.inputs` and are not served. The selected caption track is explicitly enabled in AVPlayer, independently of system caption preferences.

## Seeking and buffering

Remuxing starts at a preceding demuxer keyframe. FFmpeg reads preroll with original timestamps; a packet filter with `amount=0` discards only pictures before that random-access point, including leading open-GOP pictures that depend on an earlier GOP. Compressed payloads of retained pictures are untouched. Beamly measures the first output video timestamp and maps the generated timeline back to the original movie, including B-frame delay. Initial resume, track changes, and seeks outside the published range prepare a new stream and seek to the requested position within its initial GOP. Seeking within the published range uses AVPlayer directly.

Generated media uses growing EVENT playlists and becomes complete when FFmpeg finishes. The master advertises measured segment bitrates and is refreshed after generation completes. This is a local on-demand stream with one source video quality, not an adaptive internet streaming ladder. Native Apple TV scrubbing is limited to the currently published timeline; dedicated I-frame trick-play renditions are not supplied. Generated media remains on disk until playback stops, with the existing free-space guard.

## Verification

Automated checks use generated media, never personal movies:

- 3840 × 2160, 10-bit HEVC with PQ, BT.2020, mastering-display metadata, and content-light metadata;
- exact hashes of every decoded frame before and after remuxing;
- separate surround/stereo audio renditions and source-track selection;
- native AVPlayer loading, decoding, saved-position resume, forward/backward seeks, and caption selection;
- embedded/external text subtitles, overlapping cues, and timeline offsets;
- actual HTTP fetching of the master, media playlists, initialization segments, fragments, and captions;
- cancellation, existing MP4 playback, and queue/file preservation.

These checks do not certify physical AirPlay output, HDR display activation, every Dolby profile, Wi-Fi performance, or every receiver. Validate those on an Apple TV 4K and an HDR-capable display before describing hardware compatibility as confirmed.

## References

- [Apple HLS authoring specification](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html): video 1.5–1.10, HDR frame rate amendment for tvOS, audio groups, WebVTT timestamp mapping, manifests, and validation tools.
- [FFmpeg streamcopy](https://ffmpeg.org/ffmpeg.html#Streamcopy): copying compressed packets without decoding or encoding.
- [FFmpeg HLS muxer](https://ffmpeg.org/ffmpeg-formats.html#hls-2): fragmented MP4, variant playlists, and event playlists.
- [FFmpeg filters](https://ffmpeg.org/ffmpeg-filters.html#tonemap): explicit HDR-to-SDR compatibility conversion.
- [FFmpeg packet filtering](https://www.ffmpeg.org/ffmpeg-bitstream-filters.html#noise): timestamp-based preroll removal with payload modification disabled.
