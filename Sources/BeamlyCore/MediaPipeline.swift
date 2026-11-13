import Foundation
import Darwin
import AVFoundation

public enum PlaybackPreparationStage: String, CaseIterable, Sendable {
    case readingFile = "Reading video information…"
    case originalStream = "Preparing video without conversion…"
    case systemEncoding = "Preparing video with the system encoder…"
    case softwareEncoding = "Preparing video with the software encoder…"
    case subtitles = "Preparing subtitles…"
    case loadingPlayer = "Loading video…"
    case softwareFallback = "Retrying with the software encoder…"
}

public enum MediaPipelineError: LocalizedError {
    case missingTool(String)
    case invalidMedia(String)
    case processFailed(String, String)
    case insufficientSpace
    case timedOut

    public static func isInsufficientSpace(_ error: Error) -> Bool {
        if case .insufficientSpace? = error as? Self { return true }
        var cause = error as NSError
        for _ in 0..<4 {
            if (cause.domain == NSPOSIXErrorDomain && cause.code == Int(ENOSPC))
                || (cause.domain == NSCocoaErrorDomain && cause.code == CocoaError.fileWriteOutOfSpace.rawValue) { return true }
            guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            cause = underlying
        }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .missingTool(let name):
            return String(format: NSLocalizedString("%@ is missing. Reinstall Beamly or choose a custom FFmpeg folder in Settings.", comment: ""), name)
        case .invalidMedia(let message): return message
        case .processFailed(let name, let message): return "\(name): \(message)"
        case .insufficientSpace: return NSLocalizedString("Not enough space for the video buffer. Free up disk space and try again.", comment: "")
        case .timedOut: return NSLocalizedString("Video preparation made no progress for 90 seconds. Try software encoding.", comment: "")
        }
    }
}

@MainActor
public final class HLSJob {
    public private(set) var directory: URL?
    public private(set) var diagnostic: String?
    public private(set) var isVideoCopied = false
    public private(set) var usesOriginalDolby = false
    public private(set) var sourceOffset = 0.0
    public private(set) var audioNames: [Int: String] = [:]
    public private(set) var pendingHLSFiles: Set<String> = []
    public private(set) var earlyHLSVideoDuration: Double?
    public var generatedHLSSegments: URL? {
        pendingHLSFiles.isEmpty ? nil : directory?.appendingPathComponent(".generated", isDirectory: true)
    }
    public private(set) var subtitleNames: [SubtitleChoice: String] = [:]
    private let tools: FFmpegTools
    private var runner: ProcessRunner?
    private var captionExtraction: Task<[CaptionRendition], Error>?
    private var indexedRanges: IndexedHLSRanges?
    private var completion: Task<ProcessOutput, Error>?
    private var generation = UUID()

    public init(tools: FFmpegTools = FFmpegTools()) { self.tools = tools }

    deinit {
        runner?.cancel()
        let task = completion
        if let cache = directory {
            Task.detached {
                _ = await task?.result
                try? FileManager.default.removeItem(at: cache)
            }
        }
    }

    public func prepareNativeMP4(input: URL, info: MediaInfo, audioTrack: Int?,
                                 onFraction: (@MainActor (Double) -> Void)?,
                                 progress: @MainActor (PlaybackPreparationStage) -> Void) async throws -> URL? {
        let audio = audioTrack == nil ? info.defaultAudioTrack : info.audioTracks.first { $0.id == audioTrack }
        guard input.pathExtension.lowercased() == "mkv", info.canCopyVideo, info.videoCodec == "h264",
              !info.subtitleTracks.contains(where: \.isTextSubtitle),
              info.duration.isFinite, info.duration > 0, let audio, Self.hasSurround(audio),
              Self.dolbyTracks(startingWith: audio, in: info.audioTracks).count == 1,
              let ffmpeg = tools.ffmpegURL else { return nil }
        try validateLocalFile(input)
        stop()
        diagnostic = nil
        let currentGeneration = generation
        do {
            let cache = try await createBuffer("MP4", generation: currentGeneration)
            let file = cache.appendingPathComponent("movie.mp4")
            progress(.originalStream)
            // A front index lets AVPlayer seek anywhere through the existing HTTP range server.
            let arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", input.path,
                             "-map", "0:V:0", "-map", "0:\(audio.id)", "-c", "copy", "-movflags", "+faststart", file.lastPathComponent]
            try await mux(ffmpeg, arguments: arguments, directory: cache, generation: currentGeneration,
                          duration: info.duration, frameRate: info.frameRate, onFraction: onFraction)
            let (playable, duration) = try await AVURLAsset(url: file).load(.isPlayable, .duration)
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            guard playable, duration.seconds.isFinite, abs(duration.seconds - info.duration) <= 0.5 else {
                stop()
                return nil
            }
            sourceOffset = 0
            isVideoCopied = true
            return file
        } catch {
            guard generation == currentGeneration else { throw CancellationError() }
            stop()
            try Task.checkCancellation()
            if MediaPipelineError.isInsufficientSpace(error) { throw MediaPipelineError.insufficientSpace }
            return nil
        }
    }

    public func start(input: URL, info: MediaInfo, audioTrack: Int?, subtitle: SubtitleChoice,
                      startTime: Double = 0, hardwareEncoding: Bool, preserveQuality: Bool = true, subtitleDelay: Double = 0, audioDelay: Double = 0,
                      allowDolbyAudio: Bool = true,
                      onFraction: (@MainActor (Double) -> Void)? = nil,
                      progress: @MainActor (PlaybackPreparationStage) -> Void = { _ in }) async throws -> URL {
        stop()
        diagnostic = nil
        try validateLocalFile(input)
        guard let ffmpeg = tools.ffmpegURL else { throw MediaPipelineError.missingTool("ffmpeg") }
        if let audioTrack, !info.audioTracks.contains(where: { $0.id == audioTrack }) {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("The selected audio track is missing from the file.", comment: ""))
        }
        guard startTime.isFinite && startTime >= 0 && subtitleDelay.isFinite && audioDelay.isFinite && abs(audioDelay) <= 10 else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("Invalid playback position.", comment: ""))
        }
        // Dolby Vision needs profile-specific sample entries and manifest signaling.
        guard !info.hasDolbyVision else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("Dolby Vision remuxing is not supported. Use a compatible MP4 directly or an HDR10/SDR version.", comment: ""))
        }
        if preserveQuality, (info.isHDR || info.videoCodec == "hevc"), !info.canCopyVideo {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("This video profile cannot be preserved for Apple TV. Use a supported HEVC Main/Main 10 file, or turn off Preserve video quality for SDR conversion.", comment: ""))
        }
        let currentGeneration = generation
        let cache = try await createBuffer("HLS", generation: currentGeneration)
        isVideoCopied = preserveQuality && info.canCopyVideo
        let rendering: SubtitleRendering?
        if !isVideoCopied, subtitle != .none { progress(.subtitles) }
        do { rendering = isVideoCopied ? nil : try subtitleRendering(subtitle, input: input, info: info, directory: cache) }
        catch {
            diagnostic = error.localizedDescription
            stop()
            throw error
        }
        do {
            progress(isVideoCopied ? .originalStream : hardwareEncoding ? .systemEncoding : .softwareEncoding)
            let keyTime = isVideoCopied ? try await tools.firstVideoTimestamp(url: input, seek: startTime + info.startTime) : startTime
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            sourceOffset = isVideoCopied ? keyTime - info.startTime : startTime
            // Corrections can move all audio outside the remaining video, which must still play silently.
            let audio = audioDelay != 0 && (audioDelay >= info.duration || sourceOffset >= info.duration + audioDelay) ? nil :
                info.audioTracks.first { $0.id == audioTrack } ?? info.defaultAudioTrack
            let copyDolby = isVideoCopied && allowDolbyAudio && Self.hasDolby(audio)
            let useSystemAAC = isVideoCopied && !copyDolby && audio.map { !Self.isStereoAAC($0) } == true
            var audioTracks = audio.map { track -> [MediaTrack] in
                if copyDolby { return Self.dolbyTracks(startingWith: track, in: info.audioTracks) }
                return isVideoCopied && Self.isStereoAAC(track) ? Self.matchingAudioTracks(for: track, in: info.audioTracks) : [track]
            } ?? []
            let embeddedCaptions = isVideoCopied ? try Self.embeddedCaptions(subtitle, info: info) : []
            var sharedOutputs: [String] = []
            // With a zero-based MKV timeline, both captions and preview frames can use the main input.
            if isVideoCopied, info.videoCodec == "h264", input.pathExtension.lowercased() == "mkv",
               startTime == 0, info.startTime == 0, keyTime == 0, info.duration.isFinite, info.duration > 0 {
                if !embeddedCaptions.isEmpty {
                    let inputs = cache.appendingPathComponent(".inputs", isDirectory: true)
                    try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
                    sharedOutputs = Self.captionArguments(embeddedCaptions, in: inputs)
                }
                sharedOutputs += Self.iFrameArguments(duration: info.duration, discardBefore: keyTime)
            }
            func package(systemAAC: Bool) async throws {
                let arguments = isVideoCopied ? Self.copyArguments(input: input, info: info, audioTracks: audioTracks, keyTime: keyTime,
                    audioDelay: audioDelay, copyDolby: copyDolby, systemAAC: systemAAC) : Self.arguments(input: input, info: info, audioTrack: audioTrack,
                    subtitleRendering: rendering, startTime: startTime, hardwareEncoding: hardwareEncoding, subtitleDelay: subtitleDelay, audioDelay: audioDelay)
                // Publish only after EOF so AirPlay sees the entire seekable timeline on its first request.
                do {
                    try await mux(ffmpeg, arguments: arguments + sharedOutputs, directory: cache, generation: currentGeneration,
                                  duration: info.duration - startTime, frameRate: info.frameRate, onFraction: onFraction)
                } catch MediaPipelineError.processFailed(_, let message) where !sharedOutputs.isEmpty && !(systemAAC && message.contains("aac_at")) {
                    // An optional output can fail on damaged tracks or an older custom FFmpeg.
                    try Task.checkCancellation()
                    guard generation == currentGeneration else { throw CancellationError() }
                    sharedOutputs.removeAll()
                    Self.removeIFrames(in: cache)
                    try await mux(ffmpeg, arguments: arguments, directory: cache, generation: currentGeneration,
                                  duration: info.duration - startTime, frameRate: info.frameRate, onFraction: onFraction)
                }
            }
            do { try await package(systemAAC: useSystemAAC) }
            catch MediaPipelineError.processFailed(_, let message) where useSystemAAC && message.contains("aac_at") {
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                progress(.originalStream)
                try await package(systemAAC: false)
            } catch MediaPipelineError.processFailed(_, _) where audioTracks.count > 1 {
                // A failing alternate must not prevent playback of the selected track.
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                audioTracks = Array(audioTracks.prefix(1))
                progress(.originalStream)
                try await package(systemAAC: false)
            }
            let playlist = cache.appendingPathComponent(isVideoCopied ? "stream_0.m3u8" : "stream.m3u8")
            guard Self.isCompletePlaylist(playlist),
                  !isVideoCopied || audioTracks.isEmpty || Self.isCompletePlaylist(cache.appendingPathComponent("stream_1.m3u8")) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("FFmpeg did not create any video segments.", comment: ""))
            }
            if isVideoCopied {
                let firstPTS = try await tools.firstVideoTimestamp(url: playlist)
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                sourceOffset -= firstPTS
                let video = try Self.bandwidth(of: playlist)
                var iFrames: Bandwidth?
                if info.videoCodec == "h264" {
                    if !sharedOutputs.isEmpty {
                        // If the container duration comes from a much longer audio track, use the actual video clock.
                        if abs(info.duration - video.duration) <= 0.5 {
                            iFrames = try? Self.finishIFrames(in: cache, duration: video.duration)
                        }
                        if iFrames == nil { Self.removeIFrames(in: cache) }
                    }
                    if iFrames == nil {
                        iFrames = try await prepareIFrames(from: playlist, duration: video.duration, ffmpeg: ffmpeg, generation: currentGeneration)
                    }
                }
                if subtitle != .none || info.subtitleTracks.contains(where: \.isTextSubtitle) { progress(.subtitles) }
                let captions = try await prepareCaptions(subtitle, embedded: embeddedCaptions, alreadyExtracted: !sharedOutputs.isEmpty,
                    input: input, info: info, cache: cache, subtitleDelay: subtitleDelay, ffmpeg: ffmpeg)
                let codec = try await HLSCodec.identifier(at: cache.appendingPathComponent("init_0.mp4"))
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                let names = try await Self.writeMaster(directory: cache, codec: codec, info: info, video: video, iFrames: iFrames, audioTracks: audioTracks,
                                                       copyDolby: copyDolby, captions: captions, selectedSubtitle: subtitle)
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                audioNames = names
                usesOriginalDolby = copyDolby
                subtitleNames = Dictionary(uniqueKeysWithValues: captions.map { ($0.choice, $0.name) })
                return cache.appendingPathComponent("master.m3u8")
            }
            return playlist
        } catch {
            guard generation == currentGeneration else { throw error }
            diagnostic = error.localizedDescription
            stop()
            if MediaPipelineError.isInsufficientSpace(error) { throw MediaPipelineError.insufficientSpace }
            if !isVideoCopied, hardwareEncoding, !(error is CancellationError) {
                progress(.softwareFallback)
                return try await start(input: input, info: info, audioTrack: audioTrack, subtitle: subtitle,
                                       startTime: startTime, hardwareEncoding: false, preserveQuality: preserveQuality, subtitleDelay: subtitleDelay,
                                       audioDelay: audioDelay, allowDolbyAudio: allowDolbyAudio, onFraction: onFraction, progress: progress)
            }
            throw error
        }
    }

    /// Returns nil when this file needs the regular preparation path.
    public func prepareEarlyHLS(input: URL, info: MediaInfo, audioTrack: Int?, startTime: Double = 0, subtitle: SubtitleChoice = .none, subtitleDelay: Double,
                                onFailure: @escaping @MainActor (Error) -> Void,
                                progress: @MainActor (PlaybackPreparationStage) -> Void) async throws -> URL? {
        guard input.pathExtension.lowercased() == "mkv", info.canCopyVideo, info.startTime == 0,
              (12...86_400).contains(info.duration), startTime.isFinite, startTime >= 0, subtitleDelay.isFinite,
              let ffmpeg = tools.ffmpegURL else { return nil }
        let audio = info.audioTracks.first { $0.id == audioTrack } ?? info.defaultAudioTrack
        let separateDolby = Self.hasDolby(audio)
        if let audio, !separateDolby {
            guard info.audioTracks.count == 1, Self.isStereoAAC(audio) else { return nil }
        }
        let renditions = separateDolby ? audio.map { Self.dolbyTracks(startingWith: $0, in: info.audioTracks) } ?? [] : []

        try validateLocalFile(input)
        stop()
        diagnostic = nil
        let generation = self.generation
        do {
            return try await prepareIndexedHLS(input: input, info: info, audio: separateDolby ? nil : audio, renditions: renditions,
                                               startTime: startTime, subtitle: subtitle, subtitleDelay: subtitleDelay, ffmpeg: ffmpeg,
                                               generation: generation, onFailure: onFailure, progress: progress)
        } catch {
            guard self.generation == generation else { throw CancellationError() }
            stop()
            try Task.checkCancellation()
            if MediaPipelineError.isInsufficientSpace(error) { throw MediaPipelineError.insufficientSpace }
            return nil
        }
    }

    private func prepareIndexedHLS(input: URL, info: MediaInfo, audio: MediaTrack?, renditions: [MediaTrack], startTime: Double,
                                   subtitle: SubtitleChoice, subtitleDelay: Double,
                                   ffmpeg: URL, generation: UUID, onFailure: @escaping @MainActor (Error) -> Void,
                                   progress: @MainActor (PlaybackPreparationStage) -> Void) async throws -> URL? {
        let embedded = try Self.embeddedCaptions(subtitle, info: info)
        var captions = embedded
        if case .external(let url) = subtitle { captions.append(try Self.externalCaption(url, after: embedded)) }
        let indexing = Task.detached(priority: .userInitiated) { try MatroskaCueIndex.videoKeyframes(in: input) }
        let keyframes = try await withTaskCancellationHandler {
            try await indexing.value
        } onCancel: { indexing.cancel() }
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        let segmentLength = 6
        let maximumKeyframeInterval = 12.0
        let maximumSegmentDuration = Double(segmentLength) + maximumKeyframeInterval
        guard keyframes.first == 0, let last = keyframes.last, last < info.duration,
              info.duration - last <= 2 * maximumKeyframeInterval else { return nil }
        let videoDuration = try await tools.videoEnd(url: input, lastKeyframe: last, maxInterval: maximumKeyframeInterval + 1)
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        guard videoDuration <= info.duration + 0.5, info.duration - videoDuration <= maximumKeyframeInterval else { return nil }
        let isHEVC = info.videoCodec == "hevc"
        let audioRenditions = try await tools.indexedDolbyAudio(url: input, tracks: renditions, lastKeyframe: last, videoDuration: videoDuration)
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        // The HLS muxer cuts on the first keyframe at or beyond each successive time threshold.
        var starts = [0.0]
        for time in keyframes.dropFirst() where time >= Double(segmentLength * starts.count) {
            starts.append(time)
        }
        guard starts.count >= 2 else { return nil }
        func segments(_ times: [Double], prefix: String) -> [IndexedHLSSegment] {
            zip(times, Array(times.dropFirst()) + [videoDuration]).enumerated().map { index, pair in
                IndexedHLSSegment(name: prefix + String(format: "%06d.m4s", index), start: pair.0, end: pair.1)
            }
        }
        let videoSegments = segments(starts, prefix: "segment_0_")
        let frames = isHEVC ? [] : segments(keyframes, prefix: "iframe-")
        guard zip(keyframes, keyframes.dropFirst() + [videoDuration]).allSatisfy({ (0.001...maximumKeyframeInterval).contains($1 - $0) }),
              videoSegments.allSatisfy({ (0.01...maximumSegmentDuration).contains($0.duration) }) else {
            return nil
        }

        let cache = try await createBuffer("EarlyHLS", generation: generation)
        let inputs = cache.appendingPathComponent(".inputs", isDirectory: true)
        let generated = cache.appendingPathComponent(".generated", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: false)
        isVideoCopied = true
        usesOriginalDolby = !audioRenditions.isEmpty
        progress(.originalStream)

        // Read embedded captions separately so a damaged caption cannot abort the video producer.
        if !embedded.isEmpty {
            captionExtraction = Task { try await Self.extractEmbeddedCaptions(embedded, selected: subtitle, input: input, ffmpeg: ffmpeg, in: inputs) }
        }
        let extraction = captionExtraction

        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-copyts", "-i", input.path, "-map", "0:V:0"]
        if let audio { args += ["-map", "0:\(audio.id)"] }
        for rendition in audioRenditions { args += ["-map", "0:\(rendition.track.id)"] }
        if isHEVC { args += ["-bsf:v", "hevc_mp4toannexb"] }
        args += ["-c", "copy", "-tag:v", isHEVC ? "hvc1" : "avc1", "-sn", "-dn", "-avoid_negative_ts", "make_zero", "-f", "hls",
                 "-hls_segment_type", "fmp4", "-hls_time", String(segmentLength), "-hls_list_size", "0",
                 "-hls_playlist_type", "vod", "-hls_flags", "temp_file+independent_segments",
                 "-hls_fmp4_init_filename", audioRenditions.isEmpty ? "init_0.mp4" : "init_%v.mp4",
                 "-hls_segment_filename", audioRenditions.isEmpty ? ".generated/segment_0_%06d.m4s" : ".generated/segment_%v_%06d.m4s"]
        if audioRenditions.isEmpty {
            args += [".rendered.m3u8"]
        } else {
            let variants = ["v:0"] + audioRenditions.indices.map { "a:\($0)" }
            args += ["-var_stream_map", variants.joined(separator: " "), ".rendered_%v.m3u8"]
        }
        if !frames.isEmpty {
            args += Self.iFrameArguments(duration: videoDuration, playlist: ".rendered-iframe.m3u8", segmentPattern: ".generated/iframe-%06d.m4s")
        }

        let packaging = Task { [weak self, args] in
            guard let self else { throw CancellationError() }
            do {
                try await self.mux(ffmpeg, arguments: args, directory: cache, generation: generation,
                                   duration: videoDuration, frameRate: info.frameRate, onFraction: nil)
            } catch {
                if self.generation == generation { self.runner?.cancel() }
                throw error
            }
        }
        let firstSegments = videoSegments.prefix(2).map(\.name) + frames.prefix(1).map(\.name)
            + audioRenditions.flatMap { $0.segments.prefix(2).map(\.name) }
        let audioInits = audioRenditions.indices.map { "init_\($0 + 1).mp4" }
        let firstFiles = ["init_0.mp4"] + audioInits + (frames.isEmpty ? [] : ["iframe-init.mp4"]) + firstSegments.map { ".generated/" + $0 }
        func firstSegmentsReady() -> Bool {
            firstFiles.allSatisfy { FileManager.default.fileExists(atPath: cache.appendingPathComponent($0).path) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !firstSegmentsReady() {
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            if runner?.isFinished == true {
                try await packaging.value
                guard firstSegmentsReady() else { throw CocoaError(.fileReadCorruptFile) }
                break
            }
            guard ContinuousClock.now < deadline else { throw MediaPipelineError.timedOut }
            try await Task.sleep(for: .milliseconds(25))
        }

        for name in firstSegments {
            try FileManager.default.linkItem(at: generated.appendingPathComponent(name), to: cache.appendingPathComponent(name))
        }

        let targetDuration = Int(ceil(videoSegments.map(\.duration).max() ?? 1))
        func write(_ name: String, initialization: String, segments: [IndexedHLSSegment], iFrames: Bool = false) throws {
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
            try lines.joined(separator: "\n").write(to: cache.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        // Measure the muxer's clock against the first closed fragment while the rest is being written.
        let first = cache.appendingPathComponent(".first.m3u8")
        try write(first.lastPathComponent, initialization: "init_0.mp4", segments: [videoSegments[0]])
        let firstPTS = try await tools.firstVideoTimestamp(url: first)
        let firstAudioPTS = audio == nil ? 0 : try await tools.firstAudioTimestamp(url: first)
        for (index, rendition) in audioRenditions.enumerated() {
            let firstAudio = ".first-audio-\(index).m3u8"
            try write(firstAudio, initialization: audioInits[index], segments: [rendition.segments[0]])
            let timestamp = try await tools.firstAudioTimestamp(url: cache.appendingPathComponent(firstAudio))
            guard let planned = rendition.segments.first?.start, abs(timestamp - firstPTS - planned) < 0.002 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, rendition) in audioRenditions.enumerated() where rendition.padding != nil {
                let initialization = audioInits[index]
                group.addTask {
                    try await IndexedHLSRanges.prepareSilentAudio(for: rendition, initialization: initialization, ffmpeg: ffmpeg, directory: cache)
                }
            }
            try await group.waitForAll()
        }
        let videoCodec = try await HLSCodec.identifier(at: cache.appendingPathComponent("init_0.mp4"))
        try Task.checkCancellation()
        guard self.generation == generation, abs(firstPTS) < 0.5, abs(firstAudioPTS) < 0.5 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        sourceOffset = -firstPTS
        let ranges = IndexedHLSRanges(tools: tools, ffmpeg: ffmpeg, input: input, directory: cache, generated: generated, isHEVC: isHEVC,
                                      audioTrack: audio?.id, firstPTS: firstPTS, firstAudioPTS: firstAudioPTS,
                                      keyframes: keyframes, video: videoSegments, previews: frames, audio: audioRenditions)
        indexedRanges = ranges
        if startTime > 0 { try await ranges.prepare(at: min(startTime, videoDuration)) }
        if let selectedCaption = captions.first(where: { $0.choice == subtitle }) {
            if case .external(let url) = subtitle {
                try await Self.extractCaptions([selectedCaption], from: url, ffmpeg: ffmpeg, in: inputs)
            } else if let extraction {
                _ = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
            }
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            try writePreparedCaption(selectedCaption, info: info, cache: cache, subtitleDelay: subtitleDelay, videoDuration: videoDuration)
        }
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        try write("stream_0.m3u8", initialization: "init_0.mp4", segments: videoSegments)
        for (index, rendition) in audioRenditions.enumerated() {
            try write("stream_\(index + 1).m3u8", initialization: audioInits[index], segments: rendition.playlistSegments)
        }
        if !frames.isEmpty { try write("iframe.m3u8", initialization: "iframe-init.mp4", segments: frames, iFrames: true) }
        let backgroundCaptions = embedded.filter { $0.choice != subtitle }
        for caption in backgroundCaptions { try Self.writeCaptionPlaylist(caption, duration: videoDuration - sourceOffset, in: cache) }
        let audioCodec = audio.map { $0.codec == "ac3" ? ",ac-3" : ",mp4a.40.2" } ?? ""
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        // Estimate bandwidth for the single variant before the final fragment sizes are known.
        let average = max(1, Int(min(1_000_000_000, Double(size) * 8 / videoDuration)))
        let video = (peak: average * 3, average: average, duration: videoDuration)
        let previews: Bandwidth? = frames.isEmpty ? nil : (peak: average, average: max(1, average / 8), duration: videoDuration)
        let names = try await Self.writeMaster(directory: cache, codec: videoCodec + audioCodec, info: info, video: video, iFrames: previews,
                                               iFrameCodec: videoCodec, audioTracks: audioRenditions.map(\.track), copyDolby: usesOriginalDolby, captions: captions,
                                               selectedSubtitle: subtitle, indexedAudio: !audioRenditions.isEmpty)
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        subtitleNames = Dictionary(uniqueKeysWithValues: captions.map { ($0.choice, $0.name) })
        audioNames = names
        pendingHLSFiles = Set(videoSegments.map(\.name) + frames.map(\.name) + backgroundCaptions.map { $0.stem + ".vtt" }
                              + audioRenditions.flatMap { $0.segments.map(\.name) })
        earlyHLSVideoDuration = videoDuration

        if let extraction, !backgroundCaptions.isEmpty {
            Task { [weak self] in
                let ready: [CaptionRendition]
                do { ready = try await extraction.value }
                catch where MediaPipelineError.isInsufficientSpace(error) {
                    if self?.generation == generation { onFailure(error) }
                    return
                } catch { ready = [] }
                guard let self, self.generation == generation else { return }
                for caption in backgroundCaptions {
                    if ready.contains(where: { $0.choice == caption.choice }),
                       (try? self.writePreparedCaption(caption, info: info, cache: cache, subtitleDelay: subtitleDelay, videoDuration: videoDuration)) != nil {
                        continue
                    }
                    // Preserve an already advertised timeline even when an optional caption is unreadable.
                    try? "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n".write(
                        to: cache.appendingPathComponent(caption.stem + ".vtt"), atomically: true, encoding: .utf8)
                }
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await packaging.value
                guard self.generation == generation else { return }
                @MainActor
                func matches(_ rendered: String, plan: [IndexedHLSSegment], isIFramePlaylist: Bool = false) throws -> Bool {
                    let text = try String(contentsOf: cache.appendingPathComponent(rendered), encoding: .utf8)
                    let segments = Self.mediaSegments(in: text.components(separatedBy: .newlines))
                    return text.contains("#EXT-X-ENDLIST") && segments.count == plan.count &&
                        zip(segments, plan).enumerated().allSatisfy { index, pair in
                            let isLast = index == plan.count - 1
                            // FFmpeg can report the previous keyframe interval for the last I-frame.
                            return pair.0.filename == pair.1.name &&
                                ((isIFramePlaylist && isLast) || abs(pair.0.duration - pair.1.duration) <= (isLast ? 0.5 : 0.002))
                        }
                }
                let renderedVideo = audioRenditions.isEmpty ? ".rendered.m3u8" : ".rendered_0.m3u8"
                guard try matches(renderedVideo, plan: videoSegments),
                      try (frames.isEmpty || matches(".rendered-iframe.m3u8", plan: frames, isIFramePlaylist: true)) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                for (index, rendition) in audioRenditions.enumerated() {
                    guard try matches(".rendered_\(index + 1).m3u8", plan: rendition.segments) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
            } catch {
                guard self.generation == generation else { return }
                onFailure(error)
            }
        }
        return cache.appendingPathComponent("master.m3u8")
    }

    private func createBuffer(_ prefix: String, generation currentGeneration: UUID) async throws -> URL {
        let workspace = try await MediaCache.workspace()
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        try Self.checkDiskSpace(in: workspace)
        let cache = workspace.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        directory = cache
        return cache
    }

    private static func checkDiskSpace(in directory: URL) throws {
        if let available = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity,
           available < 256 * 1024 * 1024 {
            throw MediaPipelineError.insufficientSpace
        }
    }

    private func mux(_ ffmpeg: URL, arguments: [String], directory cache: URL, generation currentGeneration: UUID,
                     duration: Double, frameRate: Double, onFraction: (@MainActor (Double) -> Void)?) async throws {
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        try Self.checkDiskSpace(in: cache)
        let process = ProcessRunner()
        runner = process
        let execution = Task.detached(priority: .userInitiated) {
            try await process.run(executable: ffmpeg, arguments: ["-nostats", "-stats_period", "2", "-progress", ".progress"] + arguments, directory: cache)
        }
        completion = execution
        let progressFile = cache.appendingPathComponent(".progress")
        let clock = SuspendingClock()
        var deadline = clock.now.advanced(by: .seconds(90))
        var diskCheck = clock.now.advanced(by: .seconds(2))
        var progressSize = 0
        while !process.isFinished {
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            let now = clock.now
            if now >= diskCheck {
                try Self.checkDiskSpace(in: cache)
                diskCheck = now.advanced(by: .seconds(2))
            }
            if let size = (try? progressFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > progressSize {
                progressSize = size
                deadline = now.advanced(by: .seconds(90))
                if let onFraction, let fraction = Self.preparedFraction(in: progressFile, size: size, duration: duration, frameRate: frameRate) {
                    onFraction(fraction)
                }
            }
            guard now < deadline else { throw MediaPipelineError.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await execution.value
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
    }

    private static func preparedFraction(in file: URL, size: Int, duration: Double, frameRate: Double) -> Double? {
        guard duration.isFinite, duration > 0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(max(0, size - 2048)))) != nil,
              let data = try? handle.read(upToCount: 2048) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        func last(_ key: String) -> Double {
            lines.last { $0.hasPrefix(key) }.flatMap { Double($0.dropFirst(key.count)) } ?? 0
        }
        // With separate audio renditions, FFmpeg's time report can lag behind the copied video frames.
        let seconds = max(last("out_time_us=") / 1_000_000, frameRate > 0 ? last("frame=") / frameRate : 0)
        return seconds.isFinite && seconds > 0 ? min(0.99, seconds / duration) : nil
    }

    private static func hasSurround(_ audio: MediaTrack?) -> Bool {
        Self.hasDolby(audio) && (audio?.channels ?? 0) > 2
    }

    private static func hasDolby(_ audio: MediaTrack?) -> Bool {
        guard let audio else { return false }
        return ["ac3", "eac3"].contains(audio.codec)
    }

    private static func dolbyTracks(startingWith selected: MediaTrack, in tracks: [MediaTrack]) -> [MediaTrack] {
        [selected] + tracks.filter { $0.id != selected.id && hasDolby($0) }
    }

    private static func isStereoAAC(_ audio: MediaTrack) -> Bool {
        audio.codec == "aac" && audio.profile == "LC" && (audio.channels ?? 0) <= 2
    }

    private static func matchingAudioTracks(for selected: MediaTrack, in tracks: [MediaTrack]) -> [MediaTrack] {
        [selected] + tracks.filter {
            $0.id != selected.id && $0.codec == selected.codec && $0.channels == selected.channels &&
                ($0.profile == selected.profile || selected.codec == "eac3")
        }
    }

    private static func copyArguments(input: URL, info: MediaInfo, audioTracks: [MediaTrack], keyTime: Double,
                                      audioDelay: Double, copyDolby: Bool, systemAAC: Bool) -> [String] {
        // Read preroll with original timestamps, then discard packets before the selected random-access picture.
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-copyts", "-ss", String(max(0, keyTime - 2)),
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
            if copyDolby || isStereoAAC(audio) {
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

    private struct CaptionRendition {
        let choice: SubtitleChoice
        let name: String
        let language: String
        let stem: String
    }

    private static func uniqueRenditionName(_ value: String, fallback: String, names: inout Set<String>) -> String {
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

    private static func embeddedCaptions(_ selected: SubtitleChoice, info: MediaInfo) throws -> [CaptionRendition] {
        if case .embedded(let id) = selected {
            guard let track = info.subtitleTracks.first(where: { $0.id == id }) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("The selected subtitle track is missing from the file.", comment: ""))
            }
            guard track.isTextSubtitle else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("Bitmap subtitles require video conversion. Choose text subtitles or turn off Preserve video quality.", comment: ""))
            }
        }
        var names: Set<String> = []
        return info.subtitleTracks.filter(\.isTextSubtitle).map { track in
            let choice = SubtitleChoice.embedded(track.id)
            let language = MediaLanguages.normalized(track.language) ?? "und"
            let name = track.title ?? Locale(identifier: "en").localizedString(forLanguageCode: language) ?? "Subtitles"
            return CaptionRendition(choice: choice, name: Self.uniqueRenditionName(name, fallback: "Subtitles", names: &names), language: language,
                                    stem: choice == selected ? "captions" : "captions-\(track.id)")
        }
    }

    private static func captionArguments(_ renditions: [CaptionRendition], in directory: URL) -> [String] {
        renditions.flatMap { rendition in
            let stream: String
            if case .embedded(let id) = rendition.choice { stream = "0:\(id)" }
            else { stream = "0:s:0" }
            return ["-map", stream, "-c:s", "webvtt", directory.appendingPathComponent(rendition.stem + ".vtt").path]
        }
    }

    private static func extractCaptions(_ renditions: [CaptionRendition], from source: URL, ffmpeg: URL, in directory: URL) async throws {
        guard !renditions.isEmpty else { return }
        let arguments = ["-v", "error", "-nostdin", "-y", "-copyts", "-i", source.path] + captionArguments(renditions, in: directory)
        _ = try await ProcessRunner().run(executable: ffmpeg, arguments: arguments)
    }

    private static func extractEmbeddedCaptions(_ embedded: [CaptionRendition], selected: SubtitleChoice,
                                                input: URL, ffmpeg: URL, in directory: URL) async throws -> [CaptionRendition] {
        do {
            try await extractCaptions(embedded, from: input, ffmpeg: ffmpeg, in: directory)
            return embedded
        } catch where !MediaPipelineError.isInsufficientSpace(error) {
            try Task.checkCancellation()
            let required = embedded.filter { $0.choice == selected }
            try await extractCaptions(required, from: input, ffmpeg: ffmpeg, in: directory)
            return required
        }
    }

    private static func externalCaption(_ url: URL, after embedded: [CaptionRendition]) throws -> CaptionRendition {
        try validateLocalFile(url)
        guard ["srt", "ass", "ssa", "vtt", "webvtt", "sub", "txt", "mpl", "mpl2"].contains(url.pathExtension.lowercased()) else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("SRT, ASS, SSA and VTT text subtitles are supported.", comment: ""))
        }
        var names = Set(embedded.map(\.name))
        let name = uniqueRenditionName(url.lastPathComponent, fallback: "Subtitles", names: &names)
        return CaptionRendition(choice: .external(url), name: name, language: "und", stem: "captions")
    }

    private func writePreparedCaption(_ rendition: CaptionRendition, info: MediaInfo, cache: URL, subtitleDelay: Double,
                                      videoDuration: Double?) throws {
        let duration = max(0.01, (videoDuration ?? info.duration) - sourceOffset)
        let raw = cache.appendingPathComponent(".inputs").appendingPathComponent(rendition.stem + ".vtt")
        let size = try raw.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw MediaPipelineError.invalidMedia(NSLocalizedString("The subtitle file is too large.", comment: "")) }
        let origin: Double
        if case .embedded = rendition.choice { origin = sourceOffset + info.startTime }
        else { origin = sourceOffset }
        let captions = try WebVTTCaptions.retimed(String(contentsOf: raw, encoding: .utf8), offset: origin - subtitleDelay, duration: duration)
        try captions.write(to: cache.appendingPathComponent(rendition.stem + ".vtt"), atomically: true, encoding: .utf8)
        try Self.writeCaptionPlaylist(rendition, duration: duration, in: cache)
    }

    private func prepareCaptions(_ selected: SubtitleChoice, embedded: [CaptionRendition], alreadyExtracted: Bool,
                                 input: URL, info: MediaInfo, cache: URL, subtitleDelay: Double, ffmpeg: URL,
                                 videoDuration: Double? = nil) async throws -> [CaptionRendition] {
        guard !embedded.isEmpty || selected != .none else { return [] }
        let privateFolder = cache.appendingPathComponent(".inputs")
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        var renditions = embedded
        if !alreadyExtracted {
            renditions = try await Self.extractEmbeddedCaptions(embedded, selected: selected, input: input, ffmpeg: ffmpeg, in: privateFolder)
        }
        if case .external(let url) = selected {
            let rendition = try Self.externalCaption(url, after: embedded)
            try await Self.extractCaptions([rendition], from: url, ffmpeg: ffmpeg, in: privateFolder)
            renditions.append(rendition)
        }
        return try renditions.filter { rendition in
            try Task.checkCancellation()
            do {
                try writePreparedCaption(rendition, info: info, cache: cache, subtitleDelay: subtitleDelay, videoDuration: videoDuration)
                return true
            } catch {
                if rendition.choice == selected { throw error }
                return false
            }
        }
    }

    private static func writeCaptionPlaylist(_ rendition: CaptionRendition, duration: Double, in cache: URL) throws {
        let playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(duration)))\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:\(duration),\n\(rendition.stem).vtt\n#EXT-X-ENDLIST\n"
        let url = cache.appendingPathComponent(rendition.stem + ".m3u8")
        if (try? String(contentsOf: url, encoding: .utf8)) != playlist { try playlist.write(to: url, atomically: true, encoding: .utf8) }
    }

    private static func isCompletePlaylist(_ url: URL) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.contains("#EXTINF:") && contents.contains("#EXT-X-ENDLIST")
    }

    private static func iFrameArguments(duration: Double, discardBefore: Double? = nil, playlist: String = "iframe.m3u8",
                                        segmentPattern: String = "iframe-%06d.m4s") -> [String] {
        let preroll = discardBefore.map { "+lt(pts*tb\\,\($0 - 0.000001))" } ?? ""
        // Hold each keyframe until the next one. The last fragment covers the end of the timeline.
        let filter = "noise=amount=0:drop=not(key)\(preroll),setts=ts=PTS-STARTPTS:duration=if(gt(NEXT_PTS\\,PTS)\\,NEXT_PTS-PTS\\,max(DURATION\\,\(duration)/TB-(PTS-STARTPTS)))"
        return ["-map", "0:V:0", "-c:v", "copy", "-tag:v", "avc1", "-bsf:v", filter,
                "-f", "hls", "-hls_segment_type", "fmp4", "-hls_time", "0.001", "-hls_list_size", "0",
                "-hls_playlist_type", "vod", "-hls_flags", "iframes_only+independent_segments+temp_file",
                "-hls_fmp4_init_filename", "iframe-init.mp4", "-hls_segment_filename", segmentPattern, playlist]
    }

    private static func finishIFrames(in cache: URL, duration: Double) throws -> Bandwidth {
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

    private static func removeIFrames(in cache: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("iframe") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func prepareIFrames(from video: URL, duration: Double, ffmpeg: URL, generation currentGeneration: UUID) async throws -> Bandwidth? {
        guard duration > 0 else { return nil }
        let cache = video.deletingLastPathComponent()
        let arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", video.lastPathComponent]
            + Self.iFrameArguments(duration: duration)
        do {
            try await mux(ffmpeg, arguments: arguments, directory: cache, generation: currentGeneration,
                          duration: duration, frameRate: 0, onFraction: nil)
            return try Self.finishIFrames(in: cache, duration: duration)
        } catch {
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            let task = completion
            runner?.cancel()
            _ = await task?.result
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            // Scrub previews are optional, including when custom FFmpeg lacks the required filters.
            Self.removeIFrames(in: cache)
            return nil
        }
    }

    private static func writeMaster(directory: URL, codec: String, info: MediaInfo, video: Bandwidth, iFrames: Bandwidth?,
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
                guard isCompletePlaylist(url), let alternate = try? bandwidth(of: url),
                      abs(alternate.duration - selectedDuration) <= 0.5 else { continue }
                measured = alternate
            }
            let language = MediaLanguages.normalized(audio.language) ?? "und"
            let title = audio.title ?? Locale(identifier: "en").localizedString(forLanguageCode: language) ?? "Audio"
            let name = uniqueRenditionName(title, fallback: "Audio", names: &names)
            audioNames[audio.id] = name
            let count = copyDolby || isStereoAAC(audio) ? audio.channels ?? 2 : 2
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

    private typealias Bandwidth = (peak: Int, average: Int, duration: Double)

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

    private static func bandwidth(of playlist: URL) throws -> Bandwidth {
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

    /// Stops the producer during an item handoff while keeping existing segment URLs alive.
    public func cancelPendingPreparation() {
        generation = UUID()
        runner?.cancel()
        captionExtraction?.cancel()
        indexedRanges?.cancel()
        indexedRanges = nil
    }

    public func requestPendingHLSFile(_ name: String) { indexedRanges?.request(name) }

    public func stop() {
        cancelPendingPreparation()
        let task = completion
        let captions = captionExtraction
        let cache = directory
        runner = nil
        completion = nil
        captionExtraction = nil
        directory = nil
        usesOriginalDolby = false
        audioNames = [:]
        subtitleNames = [:]
        pendingHLSFiles = []
        earlyHLSVideoDuration = nil
        if let cache {
            Task.detached {
                // FFmpeg may still be closing files after cancellation; wait before deleting them.
                _ = await task?.result
                _ = await captions?.result
                try? FileManager.default.removeItem(at: cache)
            }
        }
    }

    private func subtitleRendering(_ subtitle: SubtitleChoice, input: URL, info: MediaInfo, directory: URL) throws -> SubtitleRendering? {
        guard subtitle != .none else { return nil }
        let inputs = directory.appendingPathComponent(".inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        switch subtitle {
        case .none: return nil
        case .embedded(let index):
            guard let ordinal = info.subtitleTracks.firstIndex(where: { $0.id == index }) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("The selected subtitle track is missing from the file.", comment: ""))
            }
            if info.subtitleTracks[ordinal].isBitmapSubtitle {
                return .bitmap(index)
            }
            // Fixed relative symlinks keep filenames out of FFmpeg's filter expression parser.
            try FileManager.default.createSymbolicLink(at: inputs.appendingPathComponent("source"), withDestinationURL: input)
            return .text("subtitles=filename=.inputs/source:si=\(ordinal)")
        case .external(let url):
            try validateLocalFile(url)
            let ext = url.pathExtension.lowercased()
            guard ["srt", "ass", "ssa", "vtt", "webvtt", "sub", "txt", "mpl", "mpl2"].contains(ext) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("SRT, ASS, SSA and VTT text subtitles are supported.", comment: ""))
            }
            let name = "subtitle.\(ext)"
            try FileManager.default.createSymbolicLink(at: inputs.appendingPathComponent(name), withDestinationURL: url)
            return .text("subtitles=filename=.inputs/\(name)")
        }
    }

    static func arguments(input: URL, info: MediaInfo, audioTrack: Int?, subtitleRendering: SubtitleRendering?,
                          startTime: Double, hardwareEncoding: Bool, subtitleDelay: Double = 0, audioDelay: Double = 0) -> [String] {
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
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
}
