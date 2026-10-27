import Foundation
import Darwin
import AVFoundation

public struct MediaTrack: Codable, Identifiable, Sendable, Equatable {
    /// The file's global FFmpeg stream index, not an index within audio or subtitles.
    public let id: Int
    public let codec: String
    public let language: String?
    public let title: String?
    public let channels: Int?
    public var profile: String?

    public init(id: Int, codec: String, language: String? = nil, title: String? = nil, channels: Int? = nil, profile: String? = nil) {
        self.id = id
        self.codec = codec
        self.language = language
        self.title = title
        self.channels = channels
        self.profile = profile
    }
}

public struct MediaInfo: Codable, Sendable, Equatable {
    public let duration: Double
    public let width: Int
    public let height: Int
    public let videoCodec: String?
    public let audioTracks: [MediaTrack]
    public let subtitleTracks: [MediaTrack]
    public var videoProfile: String?
    public var pixelFormat: String?
    public var videoLevel: Int?
    public var frameRate: Double = 0
    public var colorTransfer: String?
    public var colorPrimaries: String?
    public var colorSpace: String?
    public var hasDolbyVision = false
    public var startTime: Double = 0

    public var isHDR: Bool { ["smpte2084", "arib-std-b67"].contains(colorTransfer) }
    public var videoRange: String { colorTransfer == "smpte2084" ? "PQ" : colorTransfer == "arib-std-b67" ? "HLG" : "SDR" }

    public var canCopyVideo: Bool {
        guard !hasDolbyVision, width > 0, width <= 4096, height > 0, height <= 2160,
              frameRate >= 0, frameRate <= (isHDR ? 30 : 60) else { return false }
        if isHDR, pixelFormat != "yuv420p10le" || videoProfile != "Main 10" || colorPrimaries != "bt2020" || !["bt2020nc", "bt2020c"].contains(colorSpace) { return false }
        if videoCodec == "hevc" {
            return (videoProfile == nil || ["Main", "Main 10"].contains(videoProfile)) &&
                (pixelFormat == nil || ["yuv420p", "yuv420p10le"].contains(pixelFormat)) && (videoLevel ?? 0) <= 153
        }
        return videoCodec == "h264" && !isHDR &&
            (pixelFormat == nil || pixelFormat == "yuv420p") && (videoLevel ?? 0) <= 51
    }

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

enum HLSCodec {
    static func identifier(at url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        if let track = try await asset.loadTracks(withMediaType: .video).first,
           let description = try await track.load(.formatDescriptions).first,
           let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
            if let data = atoms["hvcC"] as? Data { return try hevc(data) }
            if let data = atoms["avcC"] as? Data, data.count >= 4, data[0] == 1 {
                return String(format: "avc1.%02X%02X%02X", data[1], data[2], data[3])
            }
        }
        throw MediaPipelineError.invalidMedia(NSLocalizedString("The HLS video codec could not be identified.", comment: ""))
    }

    static func hevc(_ data: Data) throws -> String {
        guard data.count >= 23, data[0] == 1 else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("The HLS video codec could not be identified.", comment: ""))
        }
        let spaces = ["", "A", "B", "C"]
        let profile = "\(spaces[Int(data[1] >> 6)])\(data[1] & 31)"
        var flags = data[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var reversed: UInt32 = 0
        for _ in 0..<32 { reversed = (reversed << 1) | (flags & 1); flags >>= 1 }
        var constraints = Array(data[6..<12])
        while constraints.count > 1, constraints.last == 0 { constraints.removeLast() }
        // ISO BMFF codec strings reverse compatibility bits and separate constraint bytes with dots.
        return "hvc1.\(profile).\(String(reversed, radix: 16, uppercase: true)).\(data[1] & 32 == 0 ? "L" : "H")\(data[12])." +
            constraints.map { String(format: "%02X", $0) }.joined(separator: ".")
    }
}

enum WebVTTCaptions {
    static func retimed(_ text: String, offset: Double, duration: Double) throws -> String {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        guard text.hasPrefix("WEBVTT"), offset.isFinite, duration.isFinite, duration > 0 else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("The subtitle timestamps are invalid.", comment: ""))
        }
        var result = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n"
        for block in blocks.dropFirst() where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains(" --> ") }) else { continue }
            let parts = lines[index].components(separatedBy: " --> ")
            let endParts = parts[1].split(separator: " ", maxSplits: 1)
            guard let start = seconds(parts[0]), let endText = endParts.first, let end = seconds(String(endText)), end >= start else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("The subtitle timestamps are invalid.", comment: ""))
            }
            if end <= offset || start - offset >= duration { continue }
            lines[index] = "\(timestamp(max(0, start - offset))) --> \(timestamp(min(duration, end - offset)))"
            if endParts.count == 2 { lines[index] += " \(endParts[1])" }
            result += lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n\n"
        }
        return result
    }

    private static func seconds(_ value: String) -> Double? {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Double($0) }
        guard fields.count == parts.count, (2...3).contains(parts.count), parts.allSatisfy({ $0.isFinite && $0 >= 0 }),
              parts.last! < 60, parts[parts.count - 2] < 60 else { return nil }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        return total < 1_000_000_000 ? total : nil
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}

public enum MediaPipelineError: LocalizedError {
    case missingTool(String)
    case invalidMedia(String)
    case processFailed(String, String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .missingTool(let name):
            return String(format: NSLocalizedString("%@ was not found. Install FFmpeg or choose the folder containing ffmpeg and ffprobe in Settings.", comment: ""), name)
        case .invalidMedia(let message): return message
        case .processFailed(let name, let message): return "\(name): \(message)"
        case .timedOut: return NSLocalizedString("The video could not be prepared within 90 seconds. Try software encoding.", comment: "")
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
            "format=duration,start_time:stream=index,codec_type,codec_name,profile,pix_fmt,level,avg_frame_rate,color_transfer,color_primaries,color_space,width,height,channels,duration:stream_tags=language,title:stream_disposition=attached_pic:stream_side_data",
            "-of", "json", url.path
        ], outputLimit: 2 * 1024 * 1024)
        return try Self.decodeProbe(output.stdout)
    }

    func firstVideoTimestamp(url: URL, seek: Double? = nil) async throws -> Double {
        guard let executable = ffprobeURL else { throw MediaPipelineError.missingTool("ffprobe") }
        var arguments = ["-v", "error", "-select_streams", "V:0"]
        if url.pathExtension == "m3u8" { arguments += ["-live_start_index", "0"] }
        // An explicit seek to zero can skip the first fMP4 GOP when its PTS is positive.
        let interval = seek.map { "\($0)%+#1" } ?? "%+#1"
        arguments += ["-read_intervals", interval,
                      "-show_entries", "packet=pts_time,flags", "-of", "json", url.path]
        let output = try await ProcessRunner().run(executable: executable, arguments: arguments)
        struct Packets: Decodable {
            struct Packet: Decodable { let pts_time: String?; let flags: String? }
            let packets: [Packet]
        }
        let packet = try JSONDecoder().decode(Packets.self, from: output.stdout).packets.first
        guard let value = packet?.pts_time.flatMap(Double.init), value.isFinite,
              packet?.flags?.contains("K") == true else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("A safe video seek point could not be found.", comment: ""))
        }
        return value
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
            let streams: [Stream]
            let format: Format?
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        guard let video = probe.streams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("No video track was found in the file.", comment: ""))
        }
        func tracks(_ kind: String) -> [MediaTrack] {
            probe.streams.filter { $0.codec_type == kind }.map {
                MediaTrack(id: $0.index, codec: $0.codec_name ?? "unknown", language: $0.tags?["language"],
                           title: $0.tags?["title"], channels: $0.channels, profile: $0.profile)
            }
        }
        let durations = ([probe.format?.duration] + probe.streams.map(\.duration)).compactMap { $0 }.compactMap(Double.init)
        let duration = durations.first(where: { $0.isFinite && $0 > 0 }) ?? 0
        var info = MediaInfo(duration: duration, width: video.width ?? 0, height: video.height ?? 0,
                         videoCodec: video.codec_name, audioTracks: tracks("audio"), subtitleTracks: tracks("subtitle"))
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

private func validateLocalFile(_ url: URL) throws {
    guard url.isFileURL,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          FileManager.default.isReadableFile(atPath: url.path) else {
        throw MediaPipelineError.invalidMedia(String(format: NSLocalizedString("File is inaccessible: %@", comment: ""), url.lastPathComponent))
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
            throw MediaPipelineError.processFailed(executable.lastPathComponent, message.isEmpty ? String(format: NSLocalizedString("The process exited with code %d.", comment: ""), process.terminationStatus) : message)
        }
        return ProcessOutput(stdout: output.value, stderr: errors.value)
    }
}

@MainActor
public final class HLSJob {
    public private(set) var directory: URL?
    public private(set) var diagnostic: String?
    public private(set) var isVideoCopied = false
    public private(set) var sourceOffset = 0.0
    private let tools: FFmpegTools
    private var runner: ProcessRunner?
    private var completion: Task<ProcessOutput, Error>?
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private var copiedVideoCodec: String?

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
                      startTime: Double, hardwareEncoding: Bool, preserveQuality: Bool = true) async throws -> URL {
        stop()
        diagnostic = nil
        try validateLocalFile(input)
        guard let ffmpeg = tools.ffmpegURL else { throw MediaPipelineError.missingTool("ffmpeg") }
        if let audioTrack, !info.audioTracks.contains(where: { $0.id == audioTrack }) {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("The selected audio track is missing from the file.", comment: ""))
        }
        guard startTime.isFinite && startTime >= 0 else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("Invalid playback position.", comment: ""))
        }
        // Dolby Vision needs profile-specific sample entries and manifest signaling.
        guard !info.hasDolbyVision else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("Dolby Vision remuxing is not supported. Use a compatible MP4 directly or an HDR10/SDR version.", comment: ""))
        }
        if preserveQuality, (info.isHDR || info.videoCodec == "hevc"), !info.canCopyVideo {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("This video profile cannot be preserved for Apple TV. Use a supported HEVC Main/Main 10 file, or turn off Preserve video quality for SDR conversion.", comment: ""))
        }
        isVideoCopied = preserveQuality && info.canCopyVideo
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-HLS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        directory = cache
        let currentGeneration = generation
        let process = ProcessRunner()
        runner = process
        let rendering: SubtitleRendering?
        do { rendering = isVideoCopied ? nil : try subtitleRendering(subtitle, input: input, info: info, directory: cache) }
        catch {
            diagnostic = error.localizedDescription
            stop()
            throw error
        }
        do {
            let audio = info.audioTracks.first { $0.id == audioTrack } ?? info.audioTracks.first
            let keyTime = isVideoCopied ? try await tools.firstVideoTimestamp(url: input, seek: startTime + info.startTime) : startTime
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            sourceOffset = isVideoCopied ? keyTime - info.startTime : startTime
            let arguments = isVideoCopied ? Self.copyArguments(input: input, info: info, audio: audio, keyTime: keyTime) : Self.arguments(input: input, info: info, audioTrack: audioTrack,
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
                        self.diagnostic = NSLocalizedString("Not enough space for the video buffer. Free up disk space and try again.", comment: "")
                        process.cancel()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                let result = await execution.result
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                if case .failure(let error) = result, self.diagnostic == nil { self.diagnostic = error.localizedDescription }
                if let codec = self.copiedVideoCodec, FileManager.default.fileExists(atPath: cache.appendingPathComponent("master.m3u8").path) {
                    do { try Self.writeMaster(directory: cache, codec: codec, info: info, audio: audio, hasSubtitles: subtitle != .none) }
                    catch { self.diagnostic = error.localizedDescription }
                }
            }
            let playlist = cache.appendingPathComponent(isVideoCopied ? "stream_0.m3u8" : "stream.m3u8")
            let deadline = Date().addingTimeInterval(90)
            func ready() -> Bool {
                guard let contents = try? String(contentsOf: playlist, encoding: .utf8) else { return false }
                let segments = contents.components(separatedBy: "#EXTINF:").count - 1
                guard segments >= 2 || (segments >= 1 && contents.contains("#EXT-X-ENDLIST")) else { return false }
                if isVideoCopied {
                    let count = audio == nil ? 1 : Self.hasSurround(audio) ? 3 : 2
                    return (0..<count).allSatisfy { index in
                            (try? String(contentsOf: cache.appendingPathComponent("stream_\(index).m3u8"), encoding: .utf8).contains("#EXTINF:")) == true
                        }
                }
                return true
            }
            while Date() < deadline {
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                if ready() { break }
                if process.isFinished {
                    do { _ = try await execution.value }
                    catch {
                        if !Task.isCancelled, let diagnostic { throw MediaPipelineError.invalidMedia(diagnostic) }
                        throw error
                    }
                    // A very short clip can end between the playlist read and process termination.
                    if ready() { break }
                    throw MediaPipelineError.invalidMedia(NSLocalizedString("FFmpeg did not create any video segments.", comment: ""))
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard ready() else { throw MediaPipelineError.timedOut }
            if isVideoCopied {
                let firstPTS = try await tools.firstVideoTimestamp(url: playlist)
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                sourceOffset -= firstPTS
                try await prepareCaptions(subtitle, input: input, info: info, cache: cache)
                let codec = try await HLSCodec.identifier(at: cache.appendingPathComponent("init_0.mp4"))
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                copiedVideoCodec = codec
                try Self.writeMaster(directory: cache, codec: codec, info: info, audio: audio, hasSubtitles: subtitle != .none)
                return cache.appendingPathComponent("master.m3u8")
            }
            return playlist
        } catch {
            guard generation == currentGeneration else { throw error }
            let copied = isVideoCopied
            diagnostic = error.localizedDescription
            stop()
            if !copied && hardwareEncoding && !(error is CancellationError) {
                return try await start(input: input, info: info, audioTrack: audioTrack, subtitle: subtitle,
                                       startTime: startTime, hardwareEncoding: false, preserveQuality: preserveQuality)
            }
            throw error
        }
    }

    private static func hasSurround(_ audio: MediaTrack?) -> Bool {
        guard let audio else { return false }
        return ["ac3", "eac3"].contains(audio.codec) && (audio.channels ?? 0) > 2
    }

    private static func copyArguments(input: URL, info: MediaInfo, audio: MediaTrack?, keyTime: Double) -> [String] {
        // Read preroll with original timestamps, then discard packets before the selected random-access picture.
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-copyts", "-ss", String(max(0, keyTime - 2)),
                    "-seek_timestamp", "1", "-i", input.path, "-map", "0:V:0", "-c:v", "copy",
                    "-bsf:v", "noise=amount=0:drop=lt(pts*tb\\,\(keyTime - 0.000001))"]
        // hvc1 keeps HEVC parameter sets in the initialization segment, as Apple requires.
        args += ["-tag:v", info.videoCodec == "hevc" ? "hvc1" : "avc1"]
        var variants = "v:0"
        if let audio {
            args += ["-map", "0:\(audio.id)"]
            if audio.codec == "aac", audio.profile == "LC", (audio.channels ?? 0) <= 2 {
                args += ["-c:a:0", "copy"]
            } else { args += ["-c:a:0", "aac", "-b:a:0", "192k", "-ac:a:0", "2", "-ar:a:0", "48000"] }
            variants += " a:0"
            if hasSurround(audio) {
                args += ["-map", "0:\(audio.id)", "-c:a:1", "copy"]
                variants += " a:1"
            }
            args += ["-bsf:a", "noise=amount=0:drop=lt(pts*tb\\,\(keyTime - 0.1))"]
        }
        args += ["-sn", "-dn", "-output_ts_offset", String(-keyTime), "-avoid_negative_ts", "make_zero", "-f", "hls", "-hls_segment_type", "fmp4",
                 "-hls_time", "6", "-hls_list_size", "0", "-hls_playlist_type", "event", "-hls_flags", "temp_file",
                 "-hls_fmp4_init_filename", "init_%v.mp4", "-hls_segment_filename", "segment_%v_%06d.m4s",
                 "-var_stream_map", variants, "stream_%v.m3u8"]
        return args
    }

    private func prepareCaptions(_ choice: SubtitleChoice, input: URL, info: MediaInfo, cache: URL) async throws {
        guard choice != .none else { return }
        let source: URL
        let map: String
        let offset: Double
        switch choice {
        case .none: return
        case .external(let url):
            try validateLocalFile(url)
            guard ["srt", "ass", "ssa", "vtt", "webvtt", "sub", "txt", "mpl", "mpl2"].contains(url.pathExtension.lowercased()) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("SRT, ASS, SSA and VTT text subtitles are supported.", comment: ""))
            }
            source = url; map = "0:s:0"; offset = sourceOffset
        case .embedded(let id):
            guard let track = info.subtitleTracks.first(where: { $0.id == id }) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("The selected subtitle track is missing from the file.", comment: ""))
            }
            guard ["subrip", "ass", "ssa", "webvtt", "mov_text", "text"].contains(track.codec) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("Bitmap subtitles require video conversion. Choose text subtitles or turn off Preserve video quality.", comment: ""))
            }
            source = input; map = "0:\(id)"; offset = sourceOffset + info.startTime
        }
        let privateFolder = cache.appendingPathComponent(".inputs")
        let duration = max(0.01, info.duration - sourceOffset)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        let raw = privateFolder.appendingPathComponent("captions.vtt")
        guard let ffmpeg = tools.ffmpegURL else { throw MediaPipelineError.missingTool("ffmpeg") }
        _ = try await ProcessRunner().run(executable: ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-copyts", "-i", source.path,
            "-map", map, "-c:s", "webvtt", raw.path])
        let size = try raw.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw MediaPipelineError.invalidMedia(NSLocalizedString("The subtitle file is too large.", comment: "")) }
        let captions = try WebVTTCaptions.retimed(String(contentsOf: raw, encoding: .utf8), offset: offset, duration: duration)
        try captions.write(to: cache.appendingPathComponent("captions.vtt"), atomically: true, encoding: .utf8)
        try "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(duration)))\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:\(duration),\ncaptions.vtt\n#EXT-X-ENDLIST\n"
            .write(to: cache.appendingPathComponent("captions.m3u8"), atomically: true, encoding: .utf8)
    }

    private static func writeMaster(directory: URL, codec: String, info: MediaInfo, audio: MediaTrack?, hasSubtitles: Bool) throws {
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
        if hasSubtitles {
            master += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"Subtitles\",LANGUAGE=\"und\",DEFAULT=YES,AUTOSELECT=YES,URI=\"captions.m3u8\"\n"
        }
        let video = try bandwidth(directory: directory, index: 0)
        let language = audio?.language.flatMap { code in
            code.count >= 2 && code.count <= 8 && code.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) } ? code : nil
        } ?? "und"
        let groups: [(String?, Int?, String?)] = audio == nil ? [(nil, nil, nil)] :
            (hasSurround(audio) ? [("surround", 2, audio?.codec == "ac3" ? "ac-3" : "ec-3"), ("stereo", 1, "mp4a.40.2")] : [("stereo", 1, "mp4a.40.2")])
        for (group, index, audioCodec) in groups {
            let sound = try index.map { try bandwidth(directory: directory, index: $0) } ?? (peak: 0, average: 0)
            if let group, let index {
                let channels = group == "surround" ? audio?.channels ?? 6 : 2
                master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(group)\",NAME=\"\(group)\",LANGUAGE=\"\(language)\",CHANNELS=\"\(channels)\",DEFAULT=YES,AUTOSELECT=YES,URI=\"stream_\(index).m3u8\"\n"
            }
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(video.peak + sound.peak),AVERAGE-BANDWIDTH=\(video.average + sound.average),RESOLUTION=\(info.width)x\(info.height),CODECS=\"\(codec)\(audioCodec.map { ",\($0)" } ?? "")\",VIDEO-RANGE=\(info.videoRange)"
            if info.frameRate > 0 { master += String(format: ",FRAME-RATE=%.3f", locale: Locale(identifier: "en_US_POSIX"), info.frameRate) }
            if let group { master += ",AUDIO=\"\(group)\"" }
            if hasSubtitles { master += ",SUBTITLES=\"subs\"" }
            master += ",CLOSED-CAPTIONS=NONE\nstream_0.m3u8\n"
        }
        let url = directory.appendingPathComponent("master.m3u8")
        if (try? String(contentsOf: url, encoding: .utf8)) != master { try master.write(to: url, atomically: true, encoding: .utf8) }
    }

    private static func bandwidth(directory: URL, index: Int) throws -> (peak: Int, average: Int) {
        let playlist = try String(contentsOf: directory.appendingPathComponent("stream_\(index).m3u8"), encoding: .utf8)
        var duration = 0.0
        var segments: [(Double, Double)] = []
        for line in playlist.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXTINF:") { duration = Double(line.dropFirst(8).split(separator: ",")[0]) ?? 0 }
            else if line.hasSuffix(".m4s"), duration > 0 {
                let size = try directory.appendingPathComponent(line).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                segments.append((duration, Double(size) * 8))
            }
        }
        let seconds = segments.reduce(0) { $0 + $1.0 }
        let bits = segments.reduce(0) { $0 + $1.1 }
        let peak = segments.map { $0.1 / $0.0 }.max() ?? 1
        return (max(1, Int(ceil(peak))), max(1, Int(ceil(bits / max(0.001, seconds)))))
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
        copiedVideoCodec = nil
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
                throw MediaPipelineError.invalidMedia(NSLocalizedString("The selected subtitle track is missing from the file.", comment: ""))
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
                throw MediaPipelineError.invalidMedia(NSLocalizedString("SRT, ASS, SSA and VTT text subtitles are supported.", comment: ""))
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
        if info.isHDR {
            filters.insert("zscale=t=linear:npl=100,format=gbrpf32le,tonemap=tonemap=mobius:desat=0,zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p", at: 0)
            arguments += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
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
