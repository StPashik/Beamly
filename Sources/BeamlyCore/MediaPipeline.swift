import Foundation
import AVFoundation

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
    let tools: FFmpegTools
    private var runner: ProcessRunner?
    var captionExtraction: Task<[CaptionRendition], Error>?
    private var indexedRanges: IndexedHLSRanges?
    private var completion: Task<ProcessOutput, Error>?
    private(set) var generation = UUID()

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
        let currentGeneration = resetPreparation()
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
        let currentGeneration = resetPreparation()
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
                return try await publishCopiedHLS(playlist, in: cache, input: input, info: info, audioTracks: audioTracks, copyDolby: copyDolby,
                    embeddedCaptions: embeddedCaptions, usedSharedOutputs: !sharedOutputs.isEmpty, subtitle: subtitle,
                    subtitleDelay: subtitleDelay, ffmpeg: ffmpeg, generation: currentGeneration, progress: progress)
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

    private func publishCopiedHLS(_ playlist: URL, in cache: URL, input: URL, info: MediaInfo, audioTracks: [MediaTrack], copyDolby: Bool,
                                  embeddedCaptions: [CaptionRendition], usedSharedOutputs: Bool, subtitle: SubtitleChoice,
                                  subtitleDelay: Double, ffmpeg: URL, generation currentGeneration: UUID,
                                  progress: @MainActor (PlaybackPreparationStage) -> Void) async throws -> URL {
        let firstPTS = try await tools.firstVideoTimestamp(url: playlist)
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        sourceOffset -= firstPTS
        let video = try HLSPlaylist.bandwidth(of: playlist)
        var iFrames: HLSPlaylist.Bandwidth?
        if info.videoCodec == "h264" {
            if usedSharedOutputs {
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
            alreadyExtracted: usedSharedOutputs, input: input, cache: cache, ffmpeg: ffmpeg)
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

    var muxFinished: Bool { runner?.isFinished == true }

    func cancelMux() { runner?.cancel() }

    func beginIndexedStream(usesOriginalDolby: Bool) {
        isVideoCopied = true
        self.usesOriginalDolby = usesOriginalDolby
    }

    func setIndexedTimeline(offset: Double, ranges: IndexedHLSRanges) {
        sourceOffset = offset
        indexedRanges = ranges
    }

    func publishIndexedStream(audioNames: [Int: String], captions: [CaptionRendition], pendingFiles: Set<String>, duration: Double) {
        subtitleNames = Dictionary(uniqueKeysWithValues: captions.map { ($0.choice, $0.name) })
        self.audioNames = audioNames
        pendingHLSFiles = pendingFiles
        earlyHLSVideoDuration = duration
    }

    func resetPreparation() -> UUID {
        stop()
        diagnostic = nil
        return generation
    }

    func createBuffer(_ prefix: String, generation currentGeneration: UUID) async throws -> URL {
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

    func mux(_ ffmpeg: URL, arguments: [String], directory cache: URL, generation currentGeneration: UUID,
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
                if let onFraction, let fraction = FFmpegProgress.fraction(in: progressFile, size: size, duration: duration, frameRate: frameRate) {
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

    private static func hasSurround(_ audio: MediaTrack?) -> Bool {
        Self.hasDolby(audio) && (audio?.channels ?? 0) > 2
    }

    static func hasDolby(_ audio: MediaTrack?) -> Bool {
        guard let audio else { return false }
        return ["ac3", "eac3"].contains(audio.codec)
    }

    static func dolbyTracks(startingWith selected: MediaTrack, in tracks: [MediaTrack]) -> [MediaTrack] {
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
        cancelMux()
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
