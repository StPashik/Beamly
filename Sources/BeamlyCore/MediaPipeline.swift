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
    public var disposition: [String: Int]?

    public var isDefault: Bool { disposition?["default"] == 1 }
    public var isOriginal: Bool { disposition?["original"] == 1 }
    public var isForced: Bool { disposition?["forced"] == 1 }
    public var isCommentary: Bool { disposition?["comment"] == 1 }
    public var isTextSubtitle: Bool { ["subrip", "ass", "ssa", "webvtt", "mov_text", "text"].contains(codec) }
    public var isBitmapSubtitle: Bool { ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"].contains(codec) }

    public init(id: Int, codec: String, language: String? = nil, title: String? = nil, channels: Int? = nil, profile: String? = nil, disposition: [String: Int]? = nil) {
        self.id = id
        self.codec = codec
        self.language = language
        self.title = title
        self.channels = channels
        self.profile = profile
        self.disposition = disposition
    }
}

public struct MediaChapter: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String?

    public init?(id: Int, start: Double, end: Double, title: String?, duration: Double) {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0,
              start >= 0, start < duration, end > start else { return nil }
        self.id = id
        self.start = start
        self.end = min(end, duration)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title?.isEmpty == false ? title : nil
    }
}

public struct MediaInfo: Codable, Sendable, Equatable {
    public let duration: Double
    public let width: Int
    public let height: Int
    public let videoCodec: String?
    public let audioTracks: [MediaTrack]
    public let subtitleTracks: [MediaTrack]
    // Optional so metadata encoded before chapter support still decodes.
    public var chapters: [MediaChapter]?
    public var videoProfile: String?
    public var pixelFormat: String?
    public var videoLevel: Int?
    public var frameRate: Double = 0
    public var colorTransfer: String?
    public var colorPrimaries: String?
    public var colorSpace: String?
    public var hasDolbyVision = false
    public var startTime: Double = 0
    public var defaultAudioTrack: MediaTrack? { audioTracks.first(where: \.isDefault) ?? audioTracks.first }

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

    public init(duration: Double, width: Int, height: Int, videoCodec: String?, audioTracks: [MediaTrack] = [], subtitleTracks: [MediaTrack] = [], chapters: [MediaChapter] = []) {
        self.duration = duration
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.chapters = chapters
    }
}

public enum SubtitleChoice: Hashable, Sendable {
    case none
    case embedded(Int)
    case external(URL)
}

public enum PlaybackPreparationStage: String, CaseIterable, Sendable {
    case readingFile = "Reading video information…"
    case originalStream = "Preparing video without conversion…"
    case systemEncoding = "Preparing video with the system encoder…"
    case softwareEncoding = "Preparing video with the software encoder…"
    case subtitles = "Preparing subtitles…"
    case loadingPlayer = "Loading video…"
    case softwareFallback = "Retrying with the software encoder…"
}

public let videoFileExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpeg", "mpg", "m2ts", "mts", "ts", "m2t", "vob", "flv", "wmv", "ogm", "ogg", "rmvb", "divx", "3gp"]

public func findSubtitleFiles(for video: URL) -> [URL] {
    guard video.isFileURL else { return [] }
    let stem = video.deletingPathExtension().lastPathComponent.lowercased()
    let files = (try? FileManager.default.contentsOfDirectory(at: video.deletingLastPathComponent(),
        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
    let otherMovies = files.filter {
        videoFileExtensions.contains($0.pathExtension.lowercased()) &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.map { $0.deletingPathExtension().lastPathComponent.lowercased() }.filter { $0.hasPrefix(stem + ".") }
    return files.filter { file in
        let name = file.deletingPathExtension().lastPathComponent.lowercased()
        return ["srt", "ass", "ssa", "vtt"].contains(file.pathExtension.lowercased()) &&
            (name == stem || name.hasPrefix(stem + ".")) &&
            !otherMovies.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) &&
            (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
            FileManager.default.isReadableFile(atPath: file.path)
    }.sorted { lhs, rhs in
        let leftExact = lhs.deletingPathExtension().lastPathComponent.lowercased() == stem
        let rightExact = rhs.deletingPathExtension().lastPathComponent.lowercased() == stem
        if leftExact != rightExact { return leftExact }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }
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

    static func jocComplexity(at url: URL) async -> UInt8? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let description = try? await track.load(.formatDescriptions).first else { return nil }
        var size = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size), size > 0 else { return nil }
        return jocComplexity(in: Data(bytes: cookie, count: size))
    }

    static func jocComplexity(in cookie: Data) -> UInt8? {
        let box = Array(cookie)
        guard box.count >= 10, box[4..<8].elementsEqual("dec3".utf8) else { return nil }
        let size = box.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard size >= 10, size <= box.count else { return nil }
        var offset = 10
        for _ in 0...Int(box[9] & 7) {
            guard offset + 3 <= size else { return nil }
            // A dependent substream adds one byte to the independent substream entry.
            offset += (box[offset + 2] & 0x1e) == 0 ? 3 : 4
        }
        guard offset + 2 <= size, box[offset] & 1 != 0, box[offset + 1] > 0 else { return nil }
        return box[offset + 1]
    }
}

enum WebVTTCaptions {
    static func retimed(_ text: String, offset: Double, duration: Double) throws -> String {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        guard text.hasPrefix("WEBVTT"), offset.isFinite, duration.isFinite, duration > 0, duration < 1_000_000_000 else {
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
            return String(format: NSLocalizedString("%@ is missing. Reinstall Beamly or choose a custom FFmpeg folder in Settings.", comment: ""), name)
        case .invalidMedia(let message): return message
        case .processFailed(let name, let message): return "\(name): \(message)"
        case .timedOut: return NSLocalizedString("Video preparation made no progress for 90 seconds. Try software encoding.", comment: "")
        }
    }
}

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
    public private(set) var usesOriginalDolby = false
    public private(set) var sourceOffset = 0.0
    public private(set) var audioNames: [Int: String] = [:]
    public private(set) var subtitleNames: [SubtitleChoice: String] = [:]
    private let tools: FFmpegTools
    private var runner: ProcessRunner?
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
              Self.matchingAudioTracks(for: audio, in: info.audioTracks).count == 1,
              let ffmpeg = tools.ffmpegURL else { return nil }
        try validateLocalFile(input)
        stop()
        diagnostic = nil
        let currentGeneration = generation
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-MP4-\(UUID().uuidString)", isDirectory: true)
        let file = cache.appendingPathComponent("movie.mp4")
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            directory = cache
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
            if error is InsufficientSpace { throw error }
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
        isVideoCopied = preserveQuality && info.canCopyVideo
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-HLS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        directory = cache
        let currentGeneration = generation
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
            let copyDolby = isVideoCopied && allowDolbyAudio && Self.hasSurround(audio)
            let useSystemAAC = isVideoCopied && !copyDolby && audio.map { !Self.isStereoAAC($0) } == true
            var audioTracks = audio.map { track in
                isVideoCopied && (copyDolby || Self.isStereoAAC(track)) ? Self.matchingAudioTracks(for: track, in: info.audioTracks) : [track]
            } ?? []
            func package(systemAAC: Bool) async throws {
                let arguments = isVideoCopied ? Self.copyArguments(input: input, info: info, audioTracks: audioTracks, keyTime: keyTime,
                    audioDelay: audioDelay, copyDolby: copyDolby, systemAAC: systemAAC) : Self.arguments(input: input, info: info, audioTrack: audioTrack,
                    subtitleRendering: rendering, startTime: startTime, hardwareEncoding: hardwareEncoding, subtitleDelay: subtitleDelay, audioDelay: audioDelay)
                // Publish only after EOF so AirPlay sees the entire seekable timeline on its first request.
                try await mux(ffmpeg, arguments: arguments, directory: cache, generation: currentGeneration,
                              duration: info.duration - startTime, frameRate: info.frameRate, onFraction: onFraction)
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
                // Start with the SDR H.264 path verified on Apple TV.
                let iFrames = info.videoCodec == "h264" ? try await prepareIFrames(from: playlist, duration: video.duration,
                    ffmpeg: ffmpeg, generation: currentGeneration) : nil
                if subtitle != .none || info.subtitleTracks.contains(where: \.isTextSubtitle) { progress(.subtitles) }
                let captions = try await prepareCaptions(subtitle, input: input, info: info, cache: cache, subtitleDelay: subtitleDelay, ffmpeg: ffmpeg)
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
            if !isVideoCopied, hardwareEncoding, !(error is CancellationError), !(error is InsufficientSpace) {
                progress(.softwareFallback)
                return try await start(input: input, info: info, audioTrack: audioTrack, subtitle: subtitle,
                                       startTime: startTime, hardwareEncoding: false, preserveQuality: preserveQuality, subtitleDelay: subtitleDelay,
                                       audioDelay: audioDelay, allowDolbyAudio: allowDolbyAudio, onFraction: onFraction, progress: progress)
            }
            throw error
        }
    }

    private struct InsufficientSpace: LocalizedError {
        var errorDescription: String? {
            NSLocalizedString("Not enough space for the video buffer. Free up disk space and try again.", comment: "")
        }
    }

    private func mux(_ ffmpeg: URL, arguments: [String], directory cache: URL, generation currentGeneration: UUID,
                     duration: Double, frameRate: Double, onFraction: (@MainActor (Double) -> Void)?) async throws {
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        let process = ProcessRunner()
        runner = process
        let execution = Task.detached(priority: .userInitiated) {
            try await process.run(executable: ffmpeg, arguments: ["-nostats", "-stats_period", "2", "-progress", ".progress"] + arguments, directory: cache)
        }
        completion = execution
        let progressFile = cache.appendingPathComponent(".progress")
        let clock = SuspendingClock()
        var deadline = clock.now.advanced(by: .seconds(90))
        var diskCheck = clock.now
        var progressSize = 0
        while !process.isFinished {
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            let now = clock.now
            if now >= diskCheck {
                let capacity = try? cache.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
                let available = max(capacity?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(capacity?.volumeAvailableCapacity ?? 0))
                if capacity != nil && available < 256 * 1024 * 1024 { throw InsufficientSpace() }
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
        guard let audio else { return false }
        return ["ac3", "eac3"].contains(audio.codec) && (audio.channels ?? 0) > 2
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
        args += ["-map", "0:V:0", "-c:v", "copy", "-bsf:v", "noise=amount=0:drop=lt(pts*tb\\,\(keyTime - 0.000001))"]
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
                 "-hls_time", "6", "-hls_list_size", "0", "-hls_playlist_type", "event", "-hls_flags", "temp_file",
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

    private func prepareCaptions(_ selected: SubtitleChoice, input: URL, info: MediaInfo, cache: URL,
                                 subtitleDelay: Double, ffmpeg: URL) async throws -> [CaptionRendition] {
        if case .embedded(let id) = selected {
            guard let track = info.subtitleTracks.first(where: { $0.id == id }) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("The selected subtitle track is missing from the file.", comment: ""))
            }
            guard track.isTextSubtitle else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("Bitmap subtitles require video conversion. Choose text subtitles or turn off Preserve video quality.", comment: ""))
            }
        }
        let textTracks = info.subtitleTracks.filter(\.isTextSubtitle)
        guard !textTracks.isEmpty || selected != .none else { return [] }
        let privateFolder = cache.appendingPathComponent(".inputs")
        let duration = max(0.01, info.duration - sourceOffset)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        var names: Set<String> = []
        var renditions = textTracks.map { track in
            let choice = SubtitleChoice.embedded(track.id)
            let language = MediaLanguages.normalized(track.language) ?? "und"
            let name = track.title ?? Locale(identifier: "en").localizedString(forLanguageCode: language) ?? "Subtitles"
            return CaptionRendition(choice: choice, name: Self.uniqueRenditionName(name, fallback: "Subtitles", names: &names), language: language,
                                    stem: choice == selected ? "captions" : "captions-\(track.id)")
        }
        func extract(from source: URL, outputs: [CaptionRendition]) async throws {
            guard !outputs.isEmpty else { return }
            var arguments = ["-v", "error", "-nostdin", "-y", "-copyts", "-i", source.path]
            for rendition in outputs {
                let stream: String
                if case .embedded(let id) = rendition.choice { stream = "0:\(id)" }
                else { stream = "0:s:0" }
                arguments += ["-map", stream, "-c:s", "webvtt", privateFolder.appendingPathComponent(rendition.stem + ".vtt").path]
            }
            _ = try await ProcessRunner().run(executable: ffmpeg, arguments: arguments)
        }
        do { try await extract(from: input, outputs: renditions) }
        catch {
            try Task.checkCancellation()
            // A broken optional track must not stop the movie or its selected captions.
            renditions = renditions.filter { $0.choice == selected }
            try await extract(from: input, outputs: renditions)
        }
        if case .external(let url) = selected {
            try validateLocalFile(url)
            guard ["srt", "ass", "ssa", "vtt", "webvtt", "sub", "txt", "mpl", "mpl2"].contains(url.pathExtension.lowercased()) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("SRT, ASS, SSA and VTT text subtitles are supported.", comment: ""))
            }
            let name = Self.uniqueRenditionName(url.lastPathComponent, fallback: "Subtitles", names: &names)
            let rendition = CaptionRendition(choice: selected, name: name, language: "und", stem: "captions")
            try await extract(from: url, outputs: [rendition])
            renditions.append(rendition)
        }
        return try renditions.filter { rendition in
            try Task.checkCancellation()
            do {
                let raw = privateFolder.appendingPathComponent(rendition.stem + ".vtt")
                let size = try raw.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 16 * 1024 * 1024 else { throw MediaPipelineError.invalidMedia(NSLocalizedString("The subtitle file is too large.", comment: "")) }
                let origin: Double
                if case .embedded = rendition.choice { origin = sourceOffset + info.startTime }
                else { origin = sourceOffset }
                let captions = try WebVTTCaptions.retimed(String(contentsOf: raw, encoding: .utf8), offset: origin - subtitleDelay, duration: duration)
                try captions.write(to: cache.appendingPathComponent(rendition.stem + ".vtt"), atomically: true, encoding: .utf8)
                try "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(duration)))\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:\(duration),\n\(rendition.stem).vtt\n#EXT-X-ENDLIST\n"
                    .write(to: cache.appendingPathComponent(rendition.stem + ".m3u8"), atomically: true, encoding: .utf8)
                return true
            } catch {
                if rendition.choice == selected { throw error }
                return false
            }
        }
    }

    private static func isCompletePlaylist(_ url: URL) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.contains("#EXTINF:") && contents.contains("#EXT-X-ENDLIST")
    }

    private func prepareIFrames(from video: URL, duration: Double, ffmpeg: URL, generation currentGeneration: UUID) async throws -> Bandwidth? {
        guard duration > 0 else { return nil }
        let cache = video.deletingLastPathComponent()
        let playlist = cache.appendingPathComponent("iframe.m3u8")
        // The copied video provides the exact seek origin. Hold each keyframe until the next one.
        let filter = "noise=amount=0:drop=not(key),setts=ts=PTS-STARTPTS:duration=if(gt(NEXT_PTS\\,PTS)\\,NEXT_PTS-PTS\\,max(DURATION\\,\(duration)/TB-(PTS-STARTPTS)))"
        let arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", video.lastPathComponent,
                         "-map", "0:V:0", "-c:v", "copy", "-tag:v", "avc1", "-bsf:v", filter,
                         "-f", "hls", "-hls_segment_type", "fmp4", "-hls_time", "0.001", "-hls_list_size", "0",
                         "-hls_playlist_type", "vod", "-hls_flags", "iframes_only+independent_segments",
                         "-hls_fmp4_init_filename", "iframe-init.mp4", "-hls_segment_filename", "iframe-%06d.m4s", playlist.lastPathComponent]
        do {
            try await mux(ffmpeg, arguments: arguments, directory: cache, generation: currentGeneration,
                          duration: duration, frameRate: 0, onFraction: nil)
            var lines = try String(contentsOf: playlist, encoding: .utf8).components(separatedBy: .newlines)
            var segments = Self.mediaSegments(in: lines)
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
            let measured = try Self.bandwidth(of: segments, in: cache, targetDuration: target)
            lines[targetLine] = "#EXT-X-TARGETDURATION:\(Int(target))"
            lines[last.durationLine] = String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), last.duration)
            try lines.joined(separator: "\n").write(to: playlist, atomically: true, encoding: .utf8)
            return measured
        } catch {
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            let task = completion
            runner?.cancel()
            _ = await task?.result
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            // Scrub previews are optional, including when custom FFmpeg lacks the required filters.
            let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("iframe") {
                try? FileManager.default.removeItem(at: file)
            }
            return nil
        }
    }

    private static func writeMaster(directory: URL, codec: String, info: MediaInfo, video: Bandwidth, iFrames: Bandwidth?,
                                    audioTracks: [MediaTrack], copyDolby: Bool, captions: [CaptionRendition],
                                    selectedSubtitle: SubtitleChoice) async throws -> [Int: String] {
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
        for caption in captions {
            let isDefault = caption.choice == selectedSubtitle ? "YES" : "NO"
            master += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(caption.name)\",LANGUAGE=\"\(caption.language)\",DEFAULT=\(isDefault),AUTOSELECT=\(isDefault),URI=\"\(caption.stem).m3u8\"\n"
        }
        var sound = (peak: 0, average: 0)
        var codecs = codec
        let group = copyDolby ? "surround" : "stereo"
        var audioNames: [Int: String] = [:]
        var names: Set<String> = []
        var selectedDuration = 0.0
        if let selected = audioTracks.first {
            let audioCodec = copyDolby ? (selected.codec == "ac3" ? "ac-3" : "ec-3") : "mp4a.40.2"
            codecs += ",\(audioCodec)"
        }
        for (index, audio) in audioTracks.enumerated() {
            let number = index + 1
            let file = "stream_\(number).m3u8"
            let url = directory.appendingPathComponent(file)
            let measured: Bandwidth
            if index == 0 {
                measured = try bandwidth(of: url)
                selectedDuration = measured.duration
            } else {
                guard isCompletePlaylist(url), let alternate = try? bandwidth(of: url),
                      abs(alternate.duration - selectedDuration) <= 0.5 else { continue }
                measured = alternate
            }
            sound.peak = max(sound.peak, measured.peak)
            sound.average = max(sound.average, measured.average)
            let language = MediaLanguages.normalized(audio.language) ?? "und"
            let title = audio.title ?? Locale(identifier: "en").localizedString(forLanguageCode: language) ?? "Audio"
            let name = uniqueRenditionName(title, fallback: "Audio", names: &names)
            audioNames[audio.id] = name
            var channels = String(copyDolby || isStereoAAC(audio) ? audio.channels ?? 2 : 2)
            if copyDolby, audio.codec == "eac3",
               let complexity = await HLSCodec.jocComplexity(at: directory.appendingPathComponent("init_\(number).mp4")) {
                channels = "\(complexity)/JOC"
            }
            let isDefault = index == 0 ? "YES" : "NO"
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(group)\",NAME=\"\(name)\",LANGUAGE=\"\(language)\",CHANNELS=\"\(channels)\",DEFAULT=\(isDefault),AUTOSELECT=\(isDefault),URI=\"\(file)\"\n"
        }
        master += "#EXT-X-STREAM-INF:BANDWIDTH=\(video.peak + sound.peak),AVERAGE-BANDWIDTH=\(video.average + sound.average),RESOLUTION=\(info.width)x\(info.height),CODECS=\"\(codecs)\",VIDEO-RANGE=\(info.videoRange)"
        if info.frameRate > 0 { master += String(format: ",FRAME-RATE=%.3f", locale: Locale(identifier: "en_US_POSIX"), info.frameRate) }
        if !audioNames.isEmpty { master += ",AUDIO=\"\(group)\"" }
        if !captions.isEmpty { master += ",SUBTITLES=\"subs\"" }
        master += ",CLOSED-CAPTIONS=NONE\nstream_0.m3u8\n"
        if let iFrames {
            master += "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=\(iFrames.peak),AVERAGE-BANDWIDTH=\(iFrames.average),RESOLUTION=\(info.width)x\(info.height),CODECS=\"\(codec)\",VIDEO-RANGE=SDR,URI=\"iframe.m3u8\"\n"
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

    public func stop() {
        generation = UUID()
        runner?.cancel()
        let task = completion
        let cache = directory
        runner = nil
        completion = nil
        directory = nil
        usesOriginalDolby = false
        audioNames = [:]
        subtitleNames = [:]
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
