import Foundation

public struct FFmpegTools: Sendable {
    public let customDirectory: URL?
    private let helpersDirectory: URL
    private let resourcesDirectory: URL?

    public init(customDirectory: URL? = nil, bundle: Bundle = .main) {
        self.customDirectory = customDirectory
        helpersDirectory = bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        resourcesDirectory = bundle.resourceURL
    }

    public var ffmpegURL: URL? { locate("ffmpeg") }
    public var ffprobeURL: URL? { locate("ffprobe") }

    private func locate(_ name: String) -> URL? {
        // ffmpeg-full includes subtitle rendering but is keg-only in Homebrew.
        let directories = [customDirectory,
                           helpersDirectory,
                           resourcesDirectory?.appendingPathComponent("Tools", isDirectory: true),
                           resourcesDirectory,
                           URL(fileURLWithPath: "/opt/homebrew/opt/ffmpeg-full/bin", isDirectory: true),
                           URL(fileURLWithPath: "/usr/local/opt/ffmpeg-full/bin", isDirectory: true),
                           URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                           URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)].compactMap { $0 }
        return directories.map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func probe(url: URL) async throws -> MediaInfo {
        try validateLocalFile(url)
        guard let executable = ffprobeURL else { throw MediaPipelineError.missingTool("ffprobe") }
        let output = try await ProcessRunner().run(executable: executable, arguments: [
            "-v", "error", "-show_entries",
            "format=duration,start_time:stream=index,codec_type,codec_name,profile,pix_fmt,level,avg_frame_rate,color_transfer,color_primaries,color_space,width,height,channels,duration:stream_tags=language,title:stream_disposition=attached_pic,default,original,forced,comment:stream_side_data:chapter=start_time,end_time:chapter_tags=title",
            "-of", "json", url.path
        ], outputLimit: 2 * 1024 * 1024)
        return try Self.decodeProbe(output.stdout)
    }

    func firstVideoTimestamp(url: URL, seek: Double? = nil) async throws -> Double {
        let packet = try await firstPacket(url: url, stream: "V:0", seek: seek)
        guard let value = packet?.pts_time.flatMap(Double.init), value.isFinite,
              packet?.flags?.contains("K") == true else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("A safe video seek point could not be found.", comment: ""))
        }
        return value
    }

    func firstAudioTimestamp(url: URL) async throws -> Double {
        let packet = try await firstPacket(url: url, stream: "a:0", seek: nil)
        guard let value = packet?.pts_time.flatMap(Double.init), value.isFinite else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    func indexedDolbyAudio(url: URL, tracks: [MediaTrack], lastKeyframe: Double, videoDuration: Double) async throws -> [IndexedHLSAudio] {
        guard let selected = tracks.first else { return [] }
        guard let ffprobe = ffprobeURL else { throw MediaPipelineError.missingTool("ffprobe") }
        @Sendable func packets(_ stream: String, _ interval: String) async throws -> [PacketList.Packet] {
            let output = try await ProcessRunner().run(executable: ffprobe, arguments: [
                "-v", "error", "-select_streams", stream, "-read_intervals", interval,
                "-show_entries", "packet=stream_index,pts_time,duration_time,size", "-of", "json", url.path
            ], outputLimit: 4 * 1024 * 1024)
            return try JSONDecoder().decode(PacketList.self, from: output.stdout).packets
        }
        async let opening = packets("a", "%+2")
        // Use the absolute end: FFprobe can seek to an earlier cluster when one dub has already ended.
        let end = videoDuration + 0.5
        async let closing = packets("a", "\(lastKeyframe)%\(end)")
        let heads = try await Dictionary(grouping: opening, by: \.stream_index)
        let tails = try await Dictionary(grouping: closing, by: \.stream_index)
        var renditions: [IndexedHLSAudio] = []
        for track in tracks {
            try Task.checkCancellation()
            guard let head = heads[track.id], let first = head.first?.pts_time.flatMap(Double.init),
                  first.isFinite, (-0.5..<2).contains(first) else { continue }
            var tail = tails[track.id] ?? []
            if tail.isEmpty, track.codec == "ac3", track.channels == 2 {
                // A short dub may have ended before the last video GOP.
                let start = max(0, videoDuration - 121)
                tail = try await packets(String(track.id), "\(start)%\(end)")
            }
            guard let last = tail.last?.pts_time.flatMap(Double.init), last.isFinite, last - videoDuration < 0.5,
                  (head + tail).allSatisfy({ $0.duration_time.flatMap(Double.init) == 0.032 }) else { continue }
            // FFmpeg cuts audio-only HLS at the first packet on or after each six-second boundary.
            // shortcut: only indexed Dolby tracks with a 32 ms cadence, extend when other packet clocks can be validated.
            let frames = ((last - first) / 0.032).rounded()
            guard frames >= 0, frames < 3_000_000, abs(first + frames * 0.032 - last) < 0.001 else { continue }
            let duration = (Int(frames) + 1) * 32
            let starts = stride(from: 0, to: duration, by: 6000).map { ($0 + 31) / 32 * 32 }.filter { $0 < duration }
            let times = (starts + [duration]).map { first + Double($0) / 1000 }
            let index = renditions.count + 1
            func segment(_ offset: Int, from start: Double, to end: Double) -> IndexedHLSSegment {
                IndexedHLSSegment(name: String(format: "segment_%d_%06d.m4s", index, offset), start: start, end: end)
            }
            let segments = zip(times, times.dropFirst()).enumerated().map { segment($0, from: $1.0, to: $1.1) }
            guard segments.count >= 2 else { continue }
            guard videoDuration - last >= 0.5 else {
                renditions.append(IndexedHLSAudio(track: track, segments: segments))
                continue
            }
            let missing = videoDuration - last - 0.032
            // shortcut: pad at most two minutes of fixed-rate stereo AC-3, extend after verifying other Dolby formats.
            guard track.codec == "ac3", track.channels == 2, duration >= 12_032, missing <= 120,
                  let size = head.first?.size.flatMap(Int.init), (128...2560).contains(size),
                  (head + tail).allSatisfy({ $0.size.flatMap(Int.init) == size }) else { continue }
            let paddedDuration = duration + Int(ceil(missing / 0.032)) * 32
            // Start padding at EOF and keep every boundary on a complete 32 ms frame.
            let paddingTimes = stride(from: duration, to: paddedDuration, by: 5984).map { first + Double($0) / 1000 }
                + [first + Double(paddedDuration) / 1000]
            let silent = zip(paddingTimes, paddingTimes.dropFirst()).enumerated().map {
                segment(segments.count + $0, from: $1.0, to: $1.1)
            }
            renditions.append(IndexedHLSAudio(track: track, segments: segments, padding: .init(bitrate: size * 250, segments: silent)))
        }
        guard renditions.first?.track.id == selected.id else { throw CocoaError(.fileReadCorruptFile) }
        return renditions
    }

    private func firstPacket(url: URL, stream: String, seek: Double?) async throws -> PacketList.Packet? {
        guard let executable = ffprobeURL else { throw MediaPipelineError.missingTool("ffprobe") }
        var arguments = ["-v", "error", "-select_streams", stream]
        if url.pathExtension == "m3u8" { arguments += ["-live_start_index", "0"] }
        // An explicit seek to zero can skip the first fMP4 GOP when its PTS is positive.
        let interval = seek.map { "\($0)%+#1" } ?? "%+#1"
        arguments += ["-read_intervals", interval,
                      "-show_entries", "packet=pts_time,flags", "-of", "json", url.path]
        let output = try await ProcessRunner().run(executable: executable, arguments: arguments)
        return try JSONDecoder().decode(PacketList.self, from: output.stdout).packets.first
    }

    func videoEnd(url: URL, lastKeyframe: Double, maxInterval: Double) async throws -> Double {
        guard let executable = ffprobeURL else { throw MediaPipelineError.missingTool("ffprobe") }
        // Read only the final GOP. The container's overall duration may include padding or a longer track.
        let arguments = ["-v", "error", "-select_streams", "V:0", "-read_intervals", "\(lastKeyframe)%+\(maxInterval)",
                         "-show_entries", "packet=pts_time,duration_time,flags", "-of", "json", url.path]
        let output = try await ProcessRunner().run(executable: executable, arguments: arguments, outputLimit: 512 * 1024)
        let packets = try JSONDecoder().decode(PacketList.self, from: output.stdout).packets
        guard let first = packets.first, first.flags?.contains("K") == true,
              let timestamp = first.pts_time.flatMap(Double.init), abs(timestamp - lastKeyframe) <= 0.002 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let end = packets.compactMap { packet -> Double? in
            guard let pts = packet.pts_time.flatMap(Double.init), pts.isFinite,
                  let duration = packet.duration_time.flatMap(Double.init), duration.isFinite, duration > 0 else { return nil }
            return pts + duration
        }.max()
        guard let end, end.isFinite, end > lastKeyframe, end - lastKeyframe < maxInterval else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return end
    }

    func videoDecodeRange(url: URL, preroll: Double, start: Double, end: Double, endsAtKeyframe: Bool) async throws -> (Double, Double) {
        guard let executable = ffprobeURL else { throw MediaPipelineError.missingTool("ffprobe") }
        let arguments = ["-v", "error", "-select_streams", "V:0", "-read_intervals", "\(preroll)%+\(end - preroll + 1.5)",
                         "-show_entries", "packet=pts_time,dts_time,flags", "-of", "json", url.path]
        let output = try await ProcessRunner().run(executable: executable, arguments: arguments, outputLimit: 512 * 1024)
        let packets = try JSONDecoder().decode(PacketList.self, from: output.stdout).packets
        func decodeTime(at timestamp: Double) -> Double? {
            packets.first {
                guard $0.flags?.contains("K") == true, let pts = $0.pts_time.flatMap(Double.init) else { return false }
                return abs(pts - timestamp) <= 0.002
            }?.dts_time.flatMap(Double.init)
        }
        guard let first = decodeTime(at: start),
              let last = endsAtKeyframe ? decodeTime(at: end) : end + 0.25,
              first.isFinite, last.isFinite, first < last, abs(first - start) < 0.5, abs(last - end) < 0.5 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (first, last)
    }

    private struct PacketList: Decodable {
        struct Packet: Decodable {
            let stream_index: Int?
            let pts_time: String?
            let dts_time: String?
            let duration_time: String?
            let flags: String?
            let size: String?
        }
        let packets: [Packet]
    }

    public func thumbnail(url: URL, at seconds: Double) async throws -> Data {
        try validateLocalFile(url)
        guard seconds.isFinite, seconds >= 0 else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("Invalid playback position.", comment: ""))
        }
        guard let executable = ffmpegURL else { throw MediaPipelineError.missingTool("ffmpeg") }
        let output = try await ProcessRunner().run(executable: executable, arguments: [
            "-v", "error", "-nostdin", "-ss", String(seconds), "-i", url.path,
            "-map", "0:V:0", "-frames:v", "1", "-vf", "scale=288:162:force_original_aspect_ratio=decrease",
            "-f", "image2pipe", "-c:v", "png", "pipe:1"
        ], outputLimit: 1024 * 1024)
        return output.stdout
    }

    static func decodeProbe(_ data: Data) throws -> MediaInfo {
        struct Probe: Decodable {
            struct Stream: Decodable {
                let index: Int
                let codec_type: String?
                let codec_name: String?
                let width: Int?
                let height: Int?
                let channels: Int?
                let duration: String?
                let tags: [String: String]?
                let disposition: [String: Int]?
                let profile: String?
                let pix_fmt: String?
                let level: Int?
                let avg_frame_rate: String?
                let color_transfer: String?
                let color_primaries: String?
                let color_space: String?
                struct SideData: Decodable { let side_data_type: String? }
                let side_data_list: [SideData]?
            }
            struct Format: Decodable { let duration: String?; let start_time: String? }
            struct Chapter: Decodable { let start_time: String?; let end_time: String?; let tags: [String: String]? }
            let streams: [Stream]
            let format: Format?
            let chapters: [Chapter]?
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        guard let video = probe.streams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("No video track was found in the file.", comment: ""))
        }
        func tracks(_ kind: String) -> [MediaTrack] {
            probe.streams.filter { $0.codec_type == kind }.map {
                MediaTrack(id: $0.index, codec: $0.codec_name ?? "unknown", language: $0.tags?["language"],
                           title: $0.tags?["title"], channels: $0.channels, profile: $0.profile, disposition: $0.disposition)
            }
        }
        let durations = ([probe.format?.duration] + probe.streams.map(\.duration)).compactMap { $0 }.compactMap(Double.init)
        let duration = durations.first(where: { $0.isFinite && $0 > 0 }) ?? 0
        var info = MediaInfo(duration: duration, width: video.width ?? 0, height: video.height ?? 0,
                         videoCodec: video.codec_name, audioTracks: tracks("audio"), subtitleTracks: tracks("subtitle"))
        info.chapters = (probe.chapters ?? []).enumerated().compactMap { index, chapter in
            guard let start = chapter.start_time.flatMap(Double.init), let end = chapter.end_time.flatMap(Double.init) else { return nil }
            return MediaChapter(id: index, start: start, end: end, title: chapter.tags?["title"], duration: duration)
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        info.videoProfile = video.profile
        info.pixelFormat = video.pix_fmt
        info.videoLevel = video.level
        let rate = video.avg_frame_rate?.split(separator: "/").compactMap { Double($0) } ?? []
        if rate.count == 2, rate[1] > 0 { info.frameRate = rate[0] / rate[1] }
        info.colorTransfer = video.color_transfer
        info.colorPrimaries = video.color_primaries
        info.colorSpace = video.color_space
        info.hasDolbyVision = video.side_data_list?.contains { $0.side_data_type?.contains("DOVI") == true } ?? false
        info.startTime = probe.format?.start_time.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } ?? 0
        return info
    }
}

func validateLocalFile(_ url: URL) throws {
    guard url.isFileURL,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          FileManager.default.isReadableFile(atPath: url.path) else {
        throw MediaPipelineError.invalidMedia(String(format: NSLocalizedString("File is inaccessible: %@", comment: ""), url.lastPathComponent))
    }
}
