import Foundation

enum FFmpegArguments {
    private static let base = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]

    static func nativeMP4(input: URL, audioTrack: Int, output: String) -> [String] {
        // A front index lets AVPlayer seek anywhere through the existing HTTP range server.
        return base + ["-i", input.path, "-map", "0:V:0", "-map", "0:\(audioTrack)",
                       "-c", "copy", "-movflags", "+faststart", output]
    }

    static func copiedHLS(input: URL, info: MediaInfo, audioTracks: [MediaTrack], keyTime: Double,
                          audioDelay: Double, copyDolby: Bool, systemAAC: Bool) -> [String] {
        // Read preroll with original timestamps, then discard packets before the selected random-access picture.
        var args = base + ["-copyts", "-ss", String(max(0, keyTime - 2)),
                           "-seek_timestamp", "1", "-i", input.path]
        // A second input shifts only audio, retaining copied video, HDR metadata, and surround packets.
        if !audioTracks.isEmpty, audioDelay != 0 {
            args += ["-ss", String(max(0, keyTime - audioDelay - 2)), "-seek_timestamp", "1", "-itsoffset", String(audioDelay), "-i", input.path]
        }
        let audioInput = audioDelay == 0 ? 0 : 1
        // Annex B lets the MP4 muxer build hvcC from in-band VPS/SPS/PPS when the MKV header lacks them.
        let annexB = info.videoCodec == "hevc" ? "hevc_mp4toannexb," : ""
        args += ["-map", "0:V:0", "-c:v", "copy", "-bsf:v", annexB + "noise=amount=0:drop=lt(pts*tb\\,\(keyTime - 0.000001))"]
        // hvc1 keeps HEVC parameter sets in the initialization segment, as Apple requires.
        args += ["-tag:v", info.videoCodec == "hevc" ? "hvc1" : "avc1"]
        var variants = "v:0"
        if let audio = audioTracks.first {
            for track in audioTracks { args += ["-map", "\(audioInput):\(track.id)"] }
            if copyDolby || audio.isStereoAAC {
                args += ["-c:a", "copy"]
            } else {
                args += systemAAC ? ["-c:a:0", "aac_at", "-aac_at_quality:a:0", "2"] : ["-c:a:0", "aac", "-aac_coder:a:0", "fast"]
                args += ["-b:a:0", "192k", "-ac:a:0", "2", "-ar:a:0", "48000"]
            }
            for index in audioTracks.indices { variants += " a:\(index)" }
            let end = audioDelay == 0 ? "" : "+gte(pts*tb\\,\(info.startTime + info.duration))"
            args += ["-bsf:a", "noise=amount=0:drop=lt(pts*tb\\,\(keyTime - 0.1))\(end)"]
        }
        // FFmpeg leaves %v literal in the initialization filename when there is only one variant.
        let initialization = audioTracks.isEmpty ? "init_0.mp4" : "init_%v.mp4"
        args += ["-sn", "-dn", "-output_ts_offset", String(-keyTime), "-avoid_negative_ts", "make_zero", "-f", "hls", "-hls_segment_type", "fmp4",
                 "-hls_time", "6", "-hls_list_size", "0", "-hls_playlist_type", "vod", "-hls_flags", "temp_file",
                 "-hls_fmp4_init_filename", initialization, "-hls_segment_filename", "segment_%v_%06d.m4s",
                 "-var_stream_map", variants, "stream_%v.m3u8"]
        return args
    }

    static func indexedHLS(input: URL, isHEVC: Bool, audioTrack: Int?, audioRenditionIDs: [Int], segmentLength: Int,
                           previewDuration: Double?) -> [String] {
        var args = base + ["-copyts", "-i", input.path, "-map", "0:V:0"]
        if let audioTrack { args += ["-map", "0:\(audioTrack)"] }
        for track in audioRenditionIDs { args += ["-map", "0:\(track)"] }
        if isHEVC { args += ["-bsf:v", "hevc_mp4toannexb"] }
        args += ["-c", "copy", "-tag:v", isHEVC ? "hvc1" : "avc1", "-sn", "-dn", "-avoid_negative_ts", "make_zero", "-f", "hls",
                 "-hls_segment_type", "fmp4", "-hls_time", String(segmentLength), "-hls_list_size", "0",
                 "-hls_playlist_type", "vod", "-hls_flags", "temp_file+independent_segments",
                 "-hls_fmp4_init_filename", audioRenditionIDs.isEmpty ? "init_0.mp4" : "init_%v.mp4",
                 "-hls_segment_filename", audioRenditionIDs.isEmpty ? ".generated/segment_0_%06d.m4s" : ".generated/segment_%v_%06d.m4s"]
        if audioRenditionIDs.isEmpty {
            args += [".rendered.m3u8"]
        } else {
            let variants = ["v:0"] + audioRenditionIDs.indices.map { "a:\($0)" }
            args += ["-var_stream_map", variants.joined(separator: " "), ".rendered_%v.m3u8"]
        }
        if let previewDuration {
            args += iFrameOutput(duration: previewDuration, playlist: ".rendered-iframe.m3u8", segmentPattern: ".generated/iframe-%06d.m4s")
        }
        return args
    }

    static func compatibilityHLS(input: URL, info: MediaInfo, audioTrack: Int?, subtitleRendering: SubtitleRendering?,
                                 startTime: Double, hardwareEncoding: Bool, subtitleDelay: Double = 0, audioDelay: Double = 0) -> [String] {
        var arguments = base
        var inputSeek = startTime
        if case .bitmap = subtitleRendering { inputSeek = max(0, startTime - max(0, subtitleDelay)) }
        if inputSeek > 0 { arguments += ["-ss", String(inputSeek)] }
        arguments += ["-i", input.path]
        let audio = audioDelay != 0 && (audioDelay >= info.duration || startTime >= info.duration + audioDelay) ? nil : audioTrack ?? info.defaultAudioTrack?.id
        if audio != nil, audioDelay != 0 {
            let audioSeek = inputSeek - audioDelay
            if audioSeek > 0 { arguments += ["-ss", String(audioSeek)] }
            if audioSeek < 0 { arguments += ["-itsoffset", String(-audioSeek)] }
            arguments += ["-i", input.path]
        }
        let preroll = startTime - inputSeek
        // Trim both media streams after rendering any bitmap cue carried across the seek point.
        if preroll > 0 { arguments += ["-ss", String(preroll)] }
        var filters = [String]()
        if case .text(let subtitleFilter) = subtitleRendering {
            // Sample captions on the shifted movie clock, then restore video/audio synchronization.
            let clock = startTime - subtitleDelay
            if clock != 0 { filters.append("setpts=PTS+(\(clock))/TB") }
            filters.append(subtitleFilter)
            if clock != 0 { filters.append("setpts=PTS-(\(clock))/TB") }
        }
        filters.append("scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2")
        if info.isHDR {
            filters.insert("zscale=t=linear:npl=100,format=gbrpf32le,tonemap=tonemap=mobius:desat=0,zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p", at: 0)
            arguments += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
        if case .bitmap(let index) = subtitleRendering {
            let source = "[0:\(index)]"
            let shift = subtitleDelay == 0 ? "" : "\(source)setpts=PTS+(\(subtitleDelay))/TB[caption];"
            let caption = subtitleDelay == 0 ? source : "[caption]"
            arguments += ["-filter_complex", "\(shift)[0:V:0]\(caption)overlay=eof_action=pass:repeatlast=0,\(filters.joined(separator: ","))[rendered]", "-map", "[rendered]"]
        } else {
            arguments += ["-map", "0:V:0", "-vf", filters.joined(separator: ",")]
        }
        if let audio { arguments += ["-map", "\(audioDelay == 0 ? 0 : 1):\(audio)"] }
        if audioDelay != 0 { arguments += ["-t", String(max(0.01, info.duration - startTime))] }
        arguments += ["-pix_fmt", "yuv420p", "-c:v", hardwareEncoding ? "h264_videotoolbox" : "libx264"]
        if hardwareEncoding {
            arguments += ["-b:v", "6000k", "-allow_sw", "1"]
        } else {
            arguments += ["-preset", "veryfast", "-crf", "20"]
        }
        // shortcut: event playlists retain the encoded movie until stop; use on-demand bounded segments for huge movies.
        arguments += ["-flags", "+cgop", "-g", "60", "-force_key_frames", "expr:gte(t,n_forced*2)",
                      "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000", "-sn", "-dn",
                      "-f", "hls", "-hls_time", "2", "-hls_list_size", "0", "-hls_playlist_type", "event",
                      "-hls_flags", "independent_segments+temp_file", "-hls_segment_filename", "segment%06d.ts", "stream.m3u8"]
        return arguments
    }

    static func previewHLS(input: URL, duration: Double) -> [String] {
        base + ["-i", input.lastPathComponent] + iFrameOutput(duration: duration)
    }

    static func iFrameOutput(duration: Double, discardBefore: Double? = nil, playlist: String = "iframe.m3u8",
                             segmentPattern: String = "iframe-%06d.m4s") -> [String] {
        let preroll = discardBefore.map { "+lt(pts*tb\\,\($0 - 0.000001))" } ?? ""
        // Hold each keyframe until the next one. The last fragment covers the end of the timeline.
        let filter = "noise=amount=0:drop=not(key)\(preroll),setts=ts=PTS-STARTPTS:duration=if(gt(NEXT_PTS\\,PTS)\\,NEXT_PTS-PTS\\,max(DURATION\\,\(duration)/TB-(PTS-STARTPTS)))"
        return ["-map", "0:V:0", "-c:v", "copy", "-tag:v", "avc1", "-bsf:v", filter,
                "-f", "hls", "-hls_segment_type", "fmp4", "-hls_time", "0.001", "-hls_list_size", "0",
                "-hls_playlist_type", "vod", "-hls_flags", "iframes_only+independent_segments+temp_file",
                "-hls_fmp4_init_filename", "iframe-init.mp4", "-hls_segment_filename", segmentPattern, playlist]
    }
}
