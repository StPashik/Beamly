import Foundation

@MainActor
enum HLSPlaylist {
    typealias Bandwidth = (peak: Int, average: Int, duration: Double)

    static func writeMaster(directory: URL, codec: String, info: MediaInfo, video: Bandwidth, iFrames: Bandwidth?,
                            iFrameCodec: String? = nil, audioTracks: [MediaTrack], copyDolby: Bool, captions: [CaptionRendition],
                            selectedSubtitle: SubtitleChoice, indexedAudio: Bool = false) async throws -> [Int: String] {
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
        for caption in captions {
            let isDefault = caption.choice == selectedSubtitle ? "YES" : "NO"
            master += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(caption.name)\",LANGUAGE=\"\(caption.language)\",DEFAULT=\(isDefault),AUTOSELECT=\(isDefault),URI=\"\(caption.stem).m3u8\"\n"
        }
        var groups: [(id: String, codec: String, peak: Int, average: Int)] = []
        var audioNames: [Int: String] = [:]
        var names: Set<String> = []
        var selectedDuration = 0.0
        for (index, audio) in audioTracks.enumerated() {
            let number = index + 1
            let file = "stream_\(number).m3u8"
            let url = directory.appendingPathComponent(file)
            let measured: Bandwidth
            if indexedAudio {
                // The source-based estimate already includes every audio track.
                measured = (peak: 0, average: 0, duration: video.duration)
            } else if index == 0 {
                measured = try bandwidth(of: url)
                selectedDuration = measured.duration
            } else {
                guard isComplete(url), let alternate = try? bandwidth(of: url),
                      abs(alternate.duration - selectedDuration) <= 0.5 else { continue }
                measured = alternate
            }
            let language = MediaLanguages.normalized(audio.language) ?? "und"
            let title = audio.title ?? Locale(identifier: "en").localizedString(forLanguageCode: language) ?? "Audio"
            let name = uniqueRenditionName(title, fallback: "Audio", names: &names)
            audioNames[audio.id] = name
            let count = copyDolby || audio.isStereoAAC ? audio.channels ?? 2 : 2
            var channels = String(count)
            if copyDolby, audio.codec == "eac3",
               let complexity = await HLSCodec.jocComplexity(at: directory.appendingPathComponent("init_\(number).mp4")) {
                channels = "\(complexity)/JOC"
            }
            let audioCodec = copyDolby ? (audio.codec == "ac3" ? "ac-3" : "ec-3") : "mp4a.40.2"
            let group = "\(audioCodec)-\(count)"
            let isDefault: String
            if let groupIndex = groups.firstIndex(where: { $0.id == group }) {
                groups[groupIndex].peak = max(groups[groupIndex].peak, measured.peak)
                groups[groupIndex].average = max(groups[groupIndex].average, measured.average)
                isDefault = "NO"
            } else {
                groups.append((group, audioCodec, measured.peak, measured.average))
                isDefault = "YES"
            }
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(group)\",NAME=\"\(name)\",LANGUAGE=\"\(language)\",CHANNELS=\"\(channels)\",DEFAULT=\(isDefault),AUTOSELECT=\(isDefault),URI=\"\(file)\"\n"
        }
        func variant(group: String?, codecs: String, peak: Int = 0, average: Int = 0) -> String {
            var line = "#EXT-X-STREAM-INF:BANDWIDTH=\(video.peak + peak),AVERAGE-BANDWIDTH=\(video.average + average),RESOLUTION=\(info.width)x\(info.height),CODECS=\"\(codecs)\",VIDEO-RANGE=\(info.videoRange)"
            if info.frameRate > 0 { line += String(format: ",FRAME-RATE=%.3f", locale: Locale(identifier: "en_US_POSIX"), info.frameRate) }
            if let group { line += ",AUDIO=\"\(group)\"" }
            if !captions.isEmpty { line += ",SUBTITLES=\"subs\"" }
            return line + ",CLOSED-CAPTIONS=NONE\nstream_0.m3u8\n"
        }
        master += groups.isEmpty ? variant(group: nil, codecs: codec) : groups.map {
            variant(group: $0.id, codecs: codec + "," + $0.codec, peak: $0.peak, average: $0.average)
        }.joined()
        if let iFrames {
            master += "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=\(iFrames.peak),AVERAGE-BANDWIDTH=\(iFrames.average),RESOLUTION=\(info.width)x\(info.height),CODECS=\"\(iFrameCodec ?? codec)\",VIDEO-RANGE=SDR,URI=\"iframe.m3u8\"\n"
        }
        try Task.checkCancellation()
        let url = directory.appendingPathComponent("master.m3u8")
        if (try? String(contentsOf: url, encoding: .utf8)) != master { try master.write(to: url, atomically: true, encoding: .utf8) }
        return audioNames
    }

    private struct MediaSegment {
        let filename: String
        let durationLine: Int
        var duration: Double
    }

    private static func mediaSegments(in lines: [String]) -> [MediaSegment] {
        var segments: [MediaSegment] = []
        var pending: (index: Int, duration: Double)?
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#EXTINF:") {
                let duration = Double(line.dropFirst(8).prefix(while: { $0 != "," })) ?? 0
                pending = duration.isFinite && duration > 0 ? (index, duration) : nil
            } else if line.hasSuffix(".m4s"), !line.hasPrefix("#"), let segment = pending {
                segments.append(MediaSegment(filename: line, durationLine: segment.index, duration: segment.duration))
                pending = nil
            }
        }
        return segments
    }

    static func bandwidth(of playlist: URL) throws -> Bandwidth {
        let lines = try String(contentsOf: playlist, encoding: .utf8).components(separatedBy: .newlines)
        return try bandwidth(of: mediaSegments(in: lines), in: playlist.deletingLastPathComponent())
    }

    private static func bandwidth(of segments: [MediaSegment], in directory: URL, targetDuration: Double? = nil) throws -> Bandwidth {
        let sizes = try segments.map { segment in
            let size = try directory.appendingPathComponent(segment.filename).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return Double(size) * 8
        }
        let seconds = segments.reduce(0) { $0 + $1.duration }
        let bits = sizes.reduce(0, +)
        var peak = zip(segments, sizes).map { $1 / $0.duration }.max() ?? 1
        if let targetDuration {
            // HLS measures peaks over contiguous intervals near the target duration.
            var windowPeak = 0.0
            for start in segments.indices {
                var duration = 0.0
                var bits = 0.0
                for index in start..<segments.count {
                    duration += segments[index].duration
                    if duration > 1.5 * targetDuration { break }
                    bits += sizes[index]
                    if duration >= 0.5 * targetDuration { windowPeak = max(windowPeak, bits / duration) }
                }
            }
            if windowPeak > 0 { peak = windowPeak }
        }
        return (max(1, Int(ceil(peak))), max(1, Int(ceil(bits / max(0.001, seconds)))), seconds)
    }

    static func writeIndexed(to url: URL, initialization: String, segments: [IndexedHLSSegment],
                             targetDuration: Int, iFrames: Bool = false) throws {
        let target = iFrames ? Int(ceil(segments.map(\.duration).max() ?? 1)) : targetDuration
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-PLAYLIST-TYPE:VOD",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"\(initialization)\""]
        if iFrames { lines.append("#EXT-X-I-FRAMES-ONLY") }
        let locale = Locale(identifier: "en_US_POSIX")
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.6f,", locale: locale, segment.duration))
            lines.append(segment.name)
        }
        lines += ["#EXT-X-ENDLIST", ""]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func matchesIndexed(_ url: URL, plan: [IndexedHLSSegment], iFrames: Bool = false) throws -> Bool {
        let text = try String(contentsOf: url, encoding: .utf8)
        let segments = mediaSegments(in: text.components(separatedBy: .newlines))
        return text.contains("#EXT-X-ENDLIST") && segments.count == plan.count &&
            zip(segments, plan).enumerated().allSatisfy { index, pair in
                let isLast = index == plan.count - 1
                // FFmpeg can report the previous keyframe interval for the last I-frame.
                return pair.0.filename == pair.1.name &&
                    ((iFrames && isLast) || abs(pair.0.duration - pair.1.duration) <= (isLast ? 0.5 : 0.002))
            }
    }

    static func writeCaptionPlaylist(_ rendition: CaptionRendition, duration: Double, in cache: URL) throws {
        let playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(duration)))\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:\(duration),\n\(rendition.stem).vtt\n#EXT-X-ENDLIST\n"
        let url = cache.appendingPathComponent(rendition.stem + ".m3u8")
        if (try? String(contentsOf: url, encoding: .utf8)) != playlist { try playlist.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func isComplete(_ url: URL) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.contains("#EXTINF:") && contents.contains("#EXT-X-ENDLIST")
    }

    static func finishIFrames(in cache: URL, duration: Double) throws -> Bandwidth {
        let playlist = cache.appendingPathComponent("iframe.m3u8")
        var lines = try String(contentsOf: playlist, encoding: .utf8).components(separatedBy: .newlines)
        var segments = mediaSegments(in: lines)
        guard segments.count > 1, lines.contains("#EXT-X-I-FRAMES-ONLY"), lines.contains("#EXT-X-ENDLIST"),
              lines.contains("#EXT-X-MAP:URI=\"iframe-init.mp4\""),
              FileManager.default.fileExists(atPath: cache.appendingPathComponent("iframe-init.mp4").path),
              let targetLine = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-TARGETDURATION:") }),
              var last = segments.popLast() else { throw CocoaError(.fileReadCorruptFile) }
        // FFmpeg may write the previous keyframe interval as the last EXTINF.
        last.duration = duration - segments.reduce(0) { $0 + $1.duration }
        guard last.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        segments.append(last)
        let target = ceil(segments.map(\.duration).max() ?? 1)
        let measured = try bandwidth(of: segments, in: cache, targetDuration: target)
        lines[targetLine] = "#EXT-X-TARGETDURATION:\(Int(target))"
        lines[last.durationLine] = String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), last.duration)
        try lines.joined(separator: "\n").write(to: playlist, atomically: true, encoding: .utf8)
        return measured
    }

    static func uniqueRenditionName(_ value: String, fallback: String, names: inout Set<String>) -> String {
        let cleaned = value.components(separatedBy: .controlCharacters.union(.newlines)).joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? fallback : cleaned
        var name = base
        var suffix = 2
        while !names.insert(name).inserted {
            name = "\(base) (\(suffix))"
            suffix += 1
        }
        return name
    }
}
