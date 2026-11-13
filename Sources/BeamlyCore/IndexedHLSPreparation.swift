import Foundation

extension HLSJob {
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
        let generation = resetPreparation()
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
        let maximumKeyframeInterval = IndexedHLSPlan.maximumKeyframeInterval
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
        guard let plan = IndexedHLSPlan(keyframes: keyframes, duration: videoDuration, isHEVC: isHEVC, audio: audioRenditions) else {
            return nil
        }

        let cache = try await createBuffer("EarlyHLS", generation: generation)
        let inputs = cache.appendingPathComponent(".inputs", isDirectory: true)
        let generated = cache.appendingPathComponent(".generated", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: false)
        beginIndexedStream(usesOriginalDolby: !plan.audio.isEmpty)
        progress(.originalStream)

        // Read embedded captions separately so a damaged caption cannot abort the video producer.
        if !embedded.isEmpty {
            captionExtraction = Task { try await SubtitlePreparation.extractEmbedded(embedded, selected: subtitle, input: input, ffmpeg: ffmpeg, in: inputs) }
        }
        let extraction = captionExtraction

        let arguments = FFmpegArguments.indexedHLS(input: input, isHEVC: isHEVC, audioTrack: audio?.id,
                                                   audioRenditionIDs: plan.audio.map(\.track.id), segmentLength: IndexedHLSPlan.segmentLength,
                                                   previewDuration: plan.previews.isEmpty ? nil : videoDuration)
        let packaging = Task { [weak self, arguments] in
            guard let self else { throw CancellationError() }
            do {
                try await self.mux(ffmpeg, arguments: arguments, directory: cache, generation: generation,
                                   duration: videoDuration, frameRate: info.frameRate, onFraction: nil)
            } catch {
                if self.generation == generation { self.cancelMux() }
                throw error
            }
        }
        try await waitForFirstSegments(of: plan, in: cache, generated: generated, packaging: packaging, generation: generation)

        let audioInits = plan.audioInitializationNames
        let targetDuration = plan.targetDuration
        // Measure the muxer's clock against the first closed fragment while the rest is being written.
        let first = cache.appendingPathComponent(".first.m3u8")
        try HLSPlaylist.writeIndexed(to: first, initialization: "init_0.mp4", segments: [plan.video[0]], targetDuration: targetDuration)
        let firstPTS = try await tools.firstVideoTimestamp(url: first)
        let firstAudioPTS = audio == nil ? 0 : try await tools.firstAudioTimestamp(url: first)
        for (index, rendition) in plan.audio.enumerated() {
            let firstAudio = cache.appendingPathComponent(".first-audio-\(index).m3u8")
            try HLSPlaylist.writeIndexed(to: firstAudio, initialization: audioInits[index],
                                         segments: [rendition.segments[0]], targetDuration: targetDuration)
            let timestamp = try await tools.firstAudioTimestamp(url: firstAudio)
            guard let planned = rendition.segments.first?.start, abs(timestamp - firstPTS - planned) < 0.002 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, rendition) in plan.audio.enumerated() where rendition.padding != nil {
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
        let ranges = IndexedHLSRanges(tools: tools, ffmpeg: ffmpeg, input: input, directory: cache, generated: generated, isHEVC: isHEVC,
                                      audioTrack: audio?.id, firstPTS: firstPTS, firstAudioPTS: firstAudioPTS,
                                      keyframes: keyframes, plan: plan)
        setIndexedTimeline(offset: -firstPTS, ranges: ranges)
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
                                     segments: plan.video, targetDuration: targetDuration)
        for (index, rendition) in plan.audio.enumerated() {
            try HLSPlaylist.writeIndexed(to: cache.appendingPathComponent("stream_\(index + 1).m3u8"), initialization: audioInits[index],
                                         segments: rendition.playlistSegments, targetDuration: targetDuration)
        }
        if !plan.previews.isEmpty {
            try HLSPlaylist.writeIndexed(to: cache.appendingPathComponent("iframe.m3u8"), initialization: "iframe-init.mp4",
                                         segments: plan.previews, targetDuration: targetDuration, iFrames: true)
        }
        let backgroundCaptions = embedded.filter { $0.choice != subtitle }
        for caption in backgroundCaptions { try HLSPlaylist.writeCaptionPlaylist(caption, duration: videoDuration - sourceOffset, in: cache) }
        let audioCodec = audio.map { $0.codec == "ac3" ? ",ac-3" : ",mp4a.40.2" } ?? ""
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        // Estimate bandwidth for the single variant before the final fragment sizes are known.
        let average = max(1, Int(min(1_000_000_000, Double(size) * 8 / videoDuration)))
        let video = (peak: average * 3, average: average, duration: videoDuration)
        let previews: HLSPlaylist.Bandwidth? = plan.previews.isEmpty ? nil : (peak: average, average: max(1, average / 8), duration: videoDuration)
        let names = try await HLSPlaylist.writeMaster(directory: cache, codec: videoCodec + audioCodec, info: info, video: video, iFrames: previews,
                                                     iFrameCodec: videoCodec, audioTracks: plan.audio.map(\.track),
                                                     copyDolby: usesOriginalDolby, captions: captions, selectedSubtitle: subtitle,
                                                     indexedAudio: !plan.audio.isEmpty)
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        publishIndexedStream(audioNames: names, captions: captions,
                             pendingFiles: Set(plan.pendingSegmentNames + backgroundCaptions.map { $0.stem + ".vtt" }),
                             duration: videoDuration)

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
                try Self.validateIndexedPlaylists(in: cache, plan: plan)
            } catch {
                guard self.generation == generation else { return }
                onFailure(error)
            }
        }
        return cache.appendingPathComponent("master.m3u8")
    }

    private func waitForFirstSegments(of plan: IndexedHLSPlan, in cache: URL, generated: URL,
                                      packaging: Task<Void, Error>, generation: UUID) async throws {
        let firstSegments = plan.firstSegmentNames
        let firstFiles = ["init_0.mp4"] + plan.audioInitializationNames + (plan.previews.isEmpty ? [] : ["iframe-init.mp4"])
            + firstSegments.map { ".generated/" + $0 }
        func firstSegmentsReady() -> Bool {
            firstFiles.allSatisfy { FileManager.default.fileExists(atPath: cache.appendingPathComponent($0).path) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !firstSegmentsReady() {
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            if muxFinished {
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
    }

    private static func validateIndexedPlaylists(in cache: URL, plan: IndexedHLSPlan) throws {
        let renderedVideo = cache.appendingPathComponent(plan.audio.isEmpty ? ".rendered.m3u8" : ".rendered_0.m3u8")
        let renderedPreviews = cache.appendingPathComponent(".rendered-iframe.m3u8")
        guard try HLSPlaylist.matchesIndexed(renderedVideo, plan: plan.video),
              try (plan.previews.isEmpty || HLSPlaylist.matchesIndexed(renderedPreviews, plan: plan.previews, iFrames: true)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (index, rendition) in plan.audio.enumerated() {
            let renderedAudio = cache.appendingPathComponent(".rendered_\(index + 1).m3u8")
            guard try HLSPlaylist.matchesIndexed(renderedAudio, plan: rendition.segments) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }
}
