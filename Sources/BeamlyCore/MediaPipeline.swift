import Foundation
import Darwin

public struct MediaTrack: Codable, Identifiable, Sendable, Equatable {
    /// The file's global FFmpeg stream index, not an index within audio or subtitles.
    public let id: Int
    public let codec: String
    public let language: String?
    public let title: String?
    public let channels: Int?

    public init(id: Int, codec: String, language: String? = nil, title: String? = nil, channels: Int? = nil) {
        self.id = id
        self.codec = codec
        self.language = language
        self.title = title
        self.channels = channels
    }
}

public struct MediaInfo: Codable, Sendable, Equatable {
    public let duration: Double
    public let width: Int
    public let height: Int
    public let videoCodec: String?
    public let audioTracks: [MediaTrack]
    public let subtitleTracks: [MediaTrack]

    public init(duration: Double, width: Int, height: Int, videoCodec: String?, audioTracks: [MediaTrack] = [], subtitleTracks: [MediaTrack] = []) {
        self.duration = duration
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
    }
}

public enum SubtitleChoice: Equatable, Sendable {
    case none
    case embedded(Int)
    case external(URL)
}

enum SubtitleRendering {
    case text(String)
    case bitmap(Int)
}

public enum MediaPipelineError: LocalizedError {
    case missingTool(String)
    case invalidMedia(String)
    case processFailed(String, String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .missingTool(let name):
            return "\(name) не найден. Установите FFmpeg или выберите папку с ffmpeg и ffprobe в настройках."
        case .invalidMedia(let message): return message
        case .processFailed(let name, let message): return "\(name): \(message)"
        case .timedOut: return "Видео не удалось подготовить за 90 секунд. Попробуйте программное кодирование."
        }
    }
}

public struct FFmpegTools: Sendable {
    public let customDirectory: URL?

    public init(customDirectory: URL? = nil) {
        self.customDirectory = customDirectory
    }

    public var ffmpegURL: URL? { locate("ffmpeg") }
    public var ffprobeURL: URL? { locate("ffprobe") }

    private func locate(_ name: String) -> URL? {
        // ffmpeg-full includes subtitle rendering but is keg-only in Homebrew.
        let directories = [customDirectory,
                           Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true),
                           Bundle.main.resourceURL,
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
            "format=duration:stream=index,codec_type,codec_name,width,height,channels,duration:stream_tags=language,title:stream_disposition=attached_pic",
            "-of", "json", url.path
        ], outputLimit: 2 * 1024 * 1024)
        return try Self.decodeProbe(output.stdout)
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
            }
            struct Format: Decodable { let duration: String? }
            let streams: [Stream]
            let format: Format?
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        guard let video = probe.streams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) else {
            throw MediaPipelineError.invalidMedia("В файле не найдена видеодорожка.")
        }
        func tracks(_ kind: String) -> [MediaTrack] {
            probe.streams.filter { $0.codec_type == kind }.map {
                MediaTrack(id: $0.index, codec: $0.codec_name ?? "unknown", language: $0.tags?["language"],
                           title: $0.tags?["title"], channels: $0.channels)
            }
        }
        let durations = ([probe.format?.duration] + probe.streams.map(\.duration)).compactMap { $0 }.compactMap(Double.init)
        let duration = durations.first(where: { $0.isFinite && $0 > 0 }) ?? 0
        return MediaInfo(duration: duration, width: video.width ?? 0, height: video.height ?? 0,
                         videoCodec: video.codec_name, audioTracks: tracks("audio"), subtitleTracks: tracks("subtitle"))
    }
}

private func validateLocalFile(_ url: URL) throws {
    guard url.isFileURL,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          FileManager.default.isReadableFile(atPath: url.path) else {
        throw MediaPipelineError.invalidMedia("Файл недоступен: \(url.lastPathComponent)")
    }
}

private struct ProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
}

private final class BoundedOutput: @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    private let lock = NSLock()

    init(limit: Int) { self.limit = limit }

    func read(_ handle: FileHandle) {
        while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
            lock.lock()
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
            lock.unlock()
        }
        try? handle.close()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func run(executable: URL, arguments: [String], directory: URL? = nil, outputLimit: Int = 64 * 1024) async throws -> ProcessOutput {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try self.execute(executable: executable, arguments: arguments, directory: directory, outputLimit: outputLimit) }
                    self.lock.lock()
                    self.finished = true
                    self.lock.unlock()
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if running.isRunning { Darwin.kill(running.processIdentifier, SIGKILL) }
        }
    }

    private func execute(executable: URL, arguments: [String], directory: URL?, outputLimit: Int) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = BoundedOutput(limit: outputLimit)
        let errors = BoundedOutput(limit: 64 * 1024)
        let readers = DispatchGroup()
        // Drain both pipes concurrently so a full stderr pipe cannot deadlock FFmpeg.
        for (pipe, buffer) in [(stdout, output), (stderr, errors)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.read(pipe.fileHandleForReading)
                readers.leave()
            }
        }
        lock.lock()
        if cancelled {
            lock.unlock()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            readers.wait()
            throw CancellationError()
        }
        self.process = process
        do {
            try process.run()
            lock.unlock()
        } catch {
            self.process = nil
            lock.unlock()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            readers.wait()
            throw error
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        process.waitUntilExit()
        readers.wait()
        lock.lock()
        let wasCancelled = cancelled
        self.process = nil
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MediaPipelineError.processFailed(executable.lastPathComponent, message.isEmpty ? "Процесс завершился с кодом \(process.terminationStatus)." : message)
        }
        return ProcessOutput(stdout: output.value, stderr: errors.value)
    }
}

@MainActor
public final class HLSJob {
    public private(set) var directory: URL?
    public private(set) var diagnostic: String?
    private let tools: FFmpegTools
    private var runner: ProcessRunner?
    private var completion: Task<ProcessOutput, Error>?
    private var monitor: Task<Void, Never>?
    private var generation = UUID()

    public init(tools: FFmpegTools = FFmpegTools()) { self.tools = tools }

    deinit {
        monitor?.cancel()
        runner?.cancel()
        let task = completion
        if let cache = directory {
            Task.detached {
                _ = await task?.result
                try? FileManager.default.removeItem(at: cache)
            }
        }
    }

    public func start(input: URL, info: MediaInfo, audioTrack: Int?, subtitle: SubtitleChoice,
                      startTime: Double, hardwareEncoding: Bool) async throws -> URL {
        stop()
        diagnostic = nil
        try validateLocalFile(input)
        guard let ffmpeg = tools.ffmpegURL else { throw MediaPipelineError.missingTool("ffmpeg") }
        if let audioTrack, !info.audioTracks.contains(where: { $0.id == audioTrack }) {
            throw MediaPipelineError.invalidMedia("Выбранная аудиодорожка отсутствует в файле.")
        }
        guard startTime.isFinite && startTime >= 0 else {
            throw MediaPipelineError.invalidMedia("Некорректная позиция воспроизведения.")
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-HLS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        directory = cache
        let currentGeneration = generation
        let process = ProcessRunner()
        runner = process
        let rendering: SubtitleRendering?
        do { rendering = try subtitleRendering(subtitle, input: input, info: info, directory: cache) }
        catch {
            diagnostic = error.localizedDescription
            stop()
            throw error
        }
        do {
            let arguments = Self.arguments(input: input, info: info, audioTrack: audioTrack,
                                           subtitleRendering: rendering, startTime: startTime, hardwareEncoding: hardwareEncoding)
            let execution = Task.detached(priority: .userInitiated) {
                try await process.run(executable: ffmpeg, arguments: arguments, directory: cache)
            }
            completion = execution
            monitor = Task { [weak self] in
                while !process.isFinished && !Task.isCancelled {
                    let capacity = try? cache.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
                    let available = max(capacity?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(capacity?.volumeAvailableCapacity ?? 0))
                    if capacity != nil && available < 256 * 1024 * 1024 {
                        guard let self, self.generation == currentGeneration else { return }
                        self.diagnostic = "Недостаточно места для видеобуфера. Освободите место на диске и повторите."
                        process.cancel()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                let result = await execution.result
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                if case .failure(let error) = result, self.diagnostic == nil { self.diagnostic = error.localizedDescription }
            }
            let playlist = cache.appendingPathComponent("stream.m3u8")
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                if let contents = try? String(contentsOf: playlist, encoding: .utf8) {
                    let segments = contents.components(separatedBy: "#EXTINF:").count - 1
                    if segments >= 2 || (segments >= 1 && contents.contains("#EXT-X-ENDLIST")) { return playlist }
                }
                if process.isFinished {
                    do { _ = try await execution.value }
                    catch {
                        if !Task.isCancelled, let diagnostic { throw MediaPipelineError.invalidMedia(diagnostic) }
                        throw error
                    }
                    // A very short clip can end between the playlist read and process termination.
                    if let contents = try? String(contentsOf: playlist, encoding: .utf8), contents.contains("#EXTINF:") { return playlist }
                    throw MediaPipelineError.invalidMedia("FFmpeg не создал видеосегменты.")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw MediaPipelineError.timedOut
        } catch {
            guard generation == currentGeneration else { throw error }
            diagnostic = error.localizedDescription
            stop()
            if hardwareEncoding && !(error is CancellationError) {
                return try await start(input: input, info: info, audioTrack: audioTrack, subtitle: subtitle,
                                       startTime: startTime, hardwareEncoding: false)
            }
            throw error
        }
    }

    public func stop() {
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        runner?.cancel()
        let task = completion
        let cache = directory
        runner = nil
        completion = nil
        directory = nil
        if let cache {
            Task.detached {
                // FFmpeg may still be closing files after cancellation; wait before deleting them.
                _ = await task?.result
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
                throw MediaPipelineError.invalidMedia("Выбранная дорожка субтитров отсутствует в файле.")
            }
            let codec = info.subtitleTracks[ordinal].codec
            if ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"].contains(codec) {
                return .bitmap(index)
            }
            // Fixed relative symlinks keep filenames out of FFmpeg's filter expression parser.
            try FileManager.default.createSymbolicLink(at: inputs.appendingPathComponent("source"), withDestinationURL: input)
            return .text("subtitles=filename=.inputs/source:si=\(ordinal)")
        case .external(let url):
            try validateLocalFile(url)
            let ext = url.pathExtension.lowercased()
            guard ["srt", "ass", "ssa", "vtt", "webvtt", "sub", "txt", "mpl", "mpl2"].contains(ext) else {
                throw MediaPipelineError.invalidMedia("Поддерживаются текстовые субтитры SRT, ASS, SSA и VTT.")
            }
            let name = "subtitle.\(ext)"
            try FileManager.default.createSymbolicLink(at: inputs.appendingPathComponent(name), withDestinationURL: url)
            return .text("subtitles=filename=.inputs/\(name)")
        }
    }

    static func arguments(input: URL, info: MediaInfo, audioTrack: Int?, subtitleRendering: SubtitleRendering?,
                          startTime: Double, hardwareEncoding: Bool) -> [String] {
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        if startTime > 0 { arguments += ["-ss", String(startTime)] }
        arguments += ["-i", input.path]
        var filters = [String]()
        if case .text(let subtitleFilter) = subtitleRendering {
            // Burn subtitles at the movie's original timestamps, then reset the HLS clock.
            if startTime > 0 { filters.append("setpts=PTS+\(startTime)/TB") }
            filters.append(subtitleFilter)
            if startTime > 0 { filters.append("setpts=PTS-\(startTime)/TB") }
        }
        filters.append("scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2")
        if case .bitmap(let index) = subtitleRendering {
            arguments += ["-filter_complex", "[0:V:0][0:\(index)]overlay=eof_action=pass:repeatlast=0,\(filters.joined(separator: ","))[rendered]", "-map", "[rendered]"]
        } else {
            arguments += ["-map", "0:V:0", "-vf", filters.joined(separator: ",")]
        }
        if let audio = audioTrack ?? info.audioTracks.first?.id { arguments += ["-map", "0:\(audio)"] }
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
