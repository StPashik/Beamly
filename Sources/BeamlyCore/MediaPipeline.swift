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
            let arguments = FFmpegArguments.nativeMP4(input: input, audioTrack: audio.id, output: file.lastPathComponent)
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
        do { rendering = isVideoCopied ? nil : try SubtitlePreparation.rendering(subtitle, input: input, info: info, directory: cache) }
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
            let useSystemAAC = isVideoCopied && !copyDolby && audio.map { !$0.isStereoAAC } == true
            var audioTracks = audio.map { track -> [MediaTrack] in
                if copyDolby { return Self.dolbyTracks(startingWith: track, in: info.audioTracks) }
                return isVideoCopied && track.isStereoAAC ? Self.matchingAudioTracks(for: track, in: info.audioTracks) : [track]
            } ?? []
            let embeddedCaptions = isVideoCopied ? try SubtitlePreparation.embeddedRenditions(subtitle, info: info) : []
            var sharedOutputs: [String] = []
            // With a zero-based MKV timeline, both captions and preview frames can use the main input.
            if isVideoCopied, info.videoCodec == "h264", input.pathExtension.lowercased() == "mkv",
               startTime == 0, info.startTime == 0, keyTime == 0, info.duration.isFinite, info.duration > 0 {
                if !embeddedCaptions.isEmpty {
                    let inputs = cache.appendingPathComponent(".inputs", isDirectory: true)
                    try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
                    sharedOutputs = SubtitlePreparation.extractionArguments(embeddedCaptions, in: inputs)
                }
                sharedOutputs += FFmpegArguments.iFrameOutput(duration: info.duration, discardBefore: keyTime)
            }
            func package(systemAAC: Bool) async throws {
                let arguments: [String]
                if isVideoCopied {
                    arguments = FFmpegArguments.copiedHLS(input: input, info: info, audioTracks: audioTracks,
                        keyTime: keyTime, audioDelay: audioDelay, copyDolby: copyDolby, systemAAC: systemAAC)
                } else {
                    arguments = FFmpegArguments.compatibilityHLS(input: input, info: info, audioTrack: audioTrack,
                        subtitleRendering: rendering, startTime: startTime, hardwareEncoding: hardwareEncoding,
                        subtitleDelay: subtitleDelay, audioDelay: audioDelay)
                }
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
            guard HLSPlaylist.isComplete(playlist),
                  !isVideoCopied || audioTracks.isEmpty || HLSPlaylist.isComplete(cache.appendingPathComponent("stream_1.m3u8")) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("FFmpeg did not create any video segments.", comment: ""))
            }
            if isVideoCopied {
                let firstPTS = try await tools.firstVideoTimestamp(url: playlist)
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                sourceOffset -= firstPTS
                let video = try HLSPlaylist.bandwidth(of: playlist)
                var iFrames: HLSPlaylist.Bandwidth?
                if info.videoCodec == "h264" {
                    if !sharedOutputs.isEmpty {
                        // If the container duration comes from a much longer audio track, use the actual video clock.
                        if abs(info.duration - video.duration) <= 0.5 {
                            iFrames = try? HLSPlaylist.finishIFrames(in: cache, duration: video.duration)
                        }
                        if iFrames == nil { Self.removeIFrames(in: cache) }
                    }
                    if iFrames == nil {
                        iFrames = try await prepareIFrames(from: playlist, duration: video.duration, ffmpeg: ffmpeg, generation: currentGeneration)
                    }
                }
                if subtitle != .none || info.subtitleTracks.contains(where: \.isTextSubtitle) { progress(.subtitles) }
                let renditions = try await SubtitlePreparation.extractRenditions(subtitle, embedded: embeddedCaptions,
                    alreadyExtracted: !sharedOutputs.isEmpty, input: input, cache: cache, ffmpeg: ffmpeg)
                let captions = try SubtitlePreparation.writeRenditions(renditions, selected: subtitle, info: info,
                    cache: cache, sourceOffset: sourceOffset, subtitleDelay: subtitleDelay)
                let codec = try await HLSCodec.identifier(at: cache.appendingPathComponent("init_0.mp4"))
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                let names = try await HLSPlaylist.writeMaster(directory: cache, codec: codec, info: info, video: video, iFrames: iFrames,
                                                              audioTracks: audioTracks, copyDolby: copyDolby, captions: captions,
                                                              selectedSubtitle: subtitle)
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
            guard info.audioTracks.count == 1, audio.isStereoAAC else { return nil }
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
        let embedded = try SubtitlePreparation.embeddedRenditions(subtitle, info: info)
        var captions = embedded
        if case .external(let url) = subtitle { captions.append(try SubtitlePreparation.externalRendition(url, after: embedded)) }
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
            captionExtraction = Task { try await SubtitlePreparation.extractEmbedded(embedded, selected: subtitle, input: input, ffmpeg: ffmpeg, in: inputs) }
        }
        let extraction = captionExtraction

        let arguments = FFmpegArguments.indexedHLS(input: input, isHEVC: isHEVC, audioTrack: audio?.id,
                                                   audioRenditionIDs: audioRenditions.map(\.track.id), segmentLength: segmentLength,
                                                   previewDuration: frames.isEmpty ? nil : videoDuration)
        let packaging = Task { [weak self, arguments] in
            guard let self else { throw CancellationError() }
            do {
                try await self.mux(ffmpeg, arguments: arguments, directory: cache, generation: generation,
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
        // Measure the muxer's clock against the first closed fragment while the rest is being written.
        let first = cache.appendingPathComponent(".first.m3u8")
        try HLSPlaylist.writeIndexed(to: first, initialization: "init_0.mp4", segments: [videoSegments[0]], targetDuration: targetDuration)
        let firstPTS = try await tools.firstVideoTimestamp(url: first)
        let firstAudioPTS = audio == nil ? 0 : try await tools.firstAudioTimestamp(url: first)
        for (index, rendition) in audioRenditions.enumerated() {
            let firstAudio = cache.appendingPathComponent(".first-audio-\(index).m3u8")
            try HLSPlaylist.writeIndexed(to: firstAudio, initialization: audioInits[index],
                                         segments: [rendition.segments[0]], targetDuration: targetDuration)
            let timestamp = try await tools.firstAudioTimestamp(url: firstAudio)
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
                try await SubtitlePreparation.extract([selectedCaption], from: url, ffmpeg: ffmpeg, in: inputs)
            } else if let extraction {
                _ = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
            }
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            try SubtitlePreparation.writeRendition(selectedCaption, info: info, cache: cache, sourceOffset: sourceOffset,
                                          subtitleDelay: subtitleDelay, videoDuration: videoDuration)
        }
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        try HLSPlaylist.writeIndexed(to: cache.appendingPathComponent("stream_0.m3u8"), initialization: "init_0.mp4",
                                     segments: videoSegments, targetDuration: targetDuration)
        for (index, rendition) in audioRenditions.enumerated() {
            try HLSPlaylist.writeIndexed(to: cache.appendingPathComponent("stream_\(index + 1).m3u8"), initialization: audioInits[index],
                                         segments: rendition.playlistSegments, targetDuration: targetDuration)
        }
        if !frames.isEmpty {
            try HLSPlaylist.writeIndexed(to: cache.appendingPathComponent("iframe.m3u8"), initialization: "iframe-init.mp4",
                                         segments: frames, targetDuration: targetDuration, iFrames: true)
        }
        let backgroundCaptions = embedded.filter { $0.choice != subtitle }
        for caption in backgroundCaptions { try HLSPlaylist.writeCaptionPlaylist(caption, duration: videoDuration - sourceOffset, in: cache) }
        let audioCodec = audio.map { $0.codec == "ac3" ? ",ac-3" : ",mp4a.40.2" } ?? ""
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        // Estimate bandwidth for the single variant before the final fragment sizes are known.
        let average = max(1, Int(min(1_000_000_000, Double(size) * 8 / videoDuration)))
        let video = (peak: average * 3, average: average, duration: videoDuration)
        let previews: HLSPlaylist.Bandwidth? = frames.isEmpty ? nil : (peak: average, average: max(1, average / 8), duration: videoDuration)
        let names = try await HLSPlaylist.writeMaster(directory: cache, codec: videoCodec + audioCodec, info: info, video: video, iFrames: previews,
                                                     iFrameCodec: videoCodec, audioTracks: audioRenditions.map(\.track),
                                                     copyDolby: usesOriginalDolby, captions: captions, selectedSubtitle: subtitle,
                                                     indexedAudio: !audioRenditions.isEmpty)
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
                SubtitlePreparation.writeOptionalRenditions(backgroundCaptions, extracted: ready, info: info, cache: cache,
                                                           sourceOffset: self.sourceOffset, subtitleDelay: subtitleDelay,
                                                           videoDuration: videoDuration)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await packaging.value
                guard self.generation == generation else { return }
                let renderedVideo = cache.appendingPathComponent(audioRenditions.isEmpty ? ".rendered.m3u8" : ".rendered_0.m3u8")
                let renderedPreviews = cache.appendingPathComponent(".rendered-iframe.m3u8")
                guard try HLSPlaylist.matchesIndexed(renderedVideo, plan: videoSegments),
                      try (frames.isEmpty || HLSPlaylist.matchesIndexed(renderedPreviews, plan: frames, iFrames: true)) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                for (index, rendition) in audioRenditions.enumerated() {
                    let renderedAudio = cache.appendingPathComponent(".rendered_\(index + 1).m3u8")
                    guard try HLSPlaylist.matchesIndexed(renderedAudio, plan: rendition.segments) else {
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

    private static func matchingAudioTracks(for selected: MediaTrack, in tracks: [MediaTrack]) -> [MediaTrack] {
        [selected] + tracks.filter {
            $0.id != selected.id && $0.codec == selected.codec && $0.channels == selected.channels &&
                ($0.profile == selected.profile || selected.codec == "eac3")
        }
    }

    private static func removeIFrames(in cache: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("iframe") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func prepareIFrames(from video: URL, duration: Double, ffmpeg: URL, generation currentGeneration: UUID) async throws -> HLSPlaylist.Bandwidth? {
        guard duration > 0 else { return nil }
        let cache = video.deletingLastPathComponent()
        let arguments = FFmpegArguments.previewHLS(input: video, duration: duration)
        do {
            try await mux(ffmpeg, arguments: arguments, directory: cache, generation: currentGeneration,
                          duration: duration, frameRate: 0, onFraction: nil)
            return try HLSPlaylist.finishIFrames(in: cache, duration: duration)
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
}
