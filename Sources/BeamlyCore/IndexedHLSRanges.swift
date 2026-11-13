import Foundation
import AVFoundation

/// Produces requested fragments independently of the sequential remux, on the same media clock.
@MainActor
final class IndexedHLSRanges {
    private struct Request {
        let segment: IndexedHLSSegment
        let index: Int
        var isPreview = false
        var audioTrack: Int? = nil
    }

    private let tools: FFmpegTools
    private let ffmpeg: URL
    private let input: URL
    private let directory: URL
    private let generated: URL
    private let isHEVC: Bool
    private let audioTrack: Int?
    private let firstPTS: Double
    private let firstAudioPTS: Double
    private let audio: [IndexedHLSAudio]
    private let keyframes: [Double]
    private let video: [IndexedHLSSegment]
    private let requests: [String: Request]
    private var pending: [Request] = []
    private var running: [String: Task<Void, Never>] = [:]
    private var cancelled = false

    init(tools: FFmpegTools, ffmpeg: URL, input: URL, directory: URL, generated: URL, isHEVC: Bool, audioTrack: Int?,
         firstPTS: Double, firstAudioPTS: Double, keyframes: [Double], plan: IndexedHLSPlan) {
        self.tools = tools
        self.ffmpeg = ffmpeg
        self.input = input
        self.directory = directory
        self.generated = generated
        self.isHEVC = isHEVC
        self.audioTrack = audioTrack
        self.firstPTS = firstPTS
        self.firstAudioPTS = firstAudioPTS
        self.audio = plan.audio
        self.keyframes = keyframes
        self.video = plan.video
        let entries = plan.video.enumerated().map { ($1.name, Request(segment: $1, index: $0, isPreview: false)) }
            + plan.previews.enumerated().map { ($1.name, Request(segment: $1, index: $0, isPreview: true)) }
        requests = Dictionary(uniqueKeysWithValues: entries + plan.audio.flatMap { rendition in
            rendition.segments.enumerated().map { ($1.name, Request(segment: $1, index: $0, audioTrack: rendition.track.id)) }
        })
    }

    func prepare(at position: Double) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for segments in [video] + audio.prefix(1).map(\.segments) {
                let index = segments.lastIndex { $0.start <= position } ?? 0
                let needed = segments[index..<min(index + 2, segments.count)].compactMap { requests[$0.name] }
                group.addTask { @MainActor in
                    for request in needed { try await self.produce(request) }
                }
            }
            try await group.waitForAll()
        }
    }

    func request(_ name: String) {
        guard !cancelled, let request = requests[name], !available(name), running[name] == nil,
              !pending.contains(where: { $0.segment.name == name }) else { return }
        if request.isPreview {
            guard pending.count < 8 else { return }
            pending.append(request)
        } else {
            if pending.count >= 8 { pending.removeLast() }
            pending.insert(request, at: 0)
        }
        startPending()
    }

    func cancel() {
        cancelled = true
        pending.removeAll()
        for task in running.values { task.cancel() }
    }

    private func startPending() {
        while !cancelled, running.count < 2, !pending.isEmpty {
            let request = pending.removeFirst()
            let name = request.segment.name
            if available(name) { continue }
            running[name] = Task { [weak self] in
                guard let self else { return }
                // The sequential remux can still fulfill a request if a short remux fails.
                try? await self.produce(request)
                self.running.removeValue(forKey: name)
                self.startPending()
            }
        }
    }

    private func available(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
            || FileManager.default.fileExists(atPath: generated.appendingPathComponent(name).path)
    }

    private func produce(_ request: Request) async throws {
        try Task.checkCancellation()
        guard !cancelled, !available(request.segment.name) else { return }
        let segment = request.segment
        let preroll = request.isPreview ? segment.start : keyframes.last { $0 <= segment.start - 1 } ?? 0
        let end = request.isPreview ? segment.start + 0.6 : segment.end + 0.6
        let work = directory.deletingLastPathComponent().appendingPathComponent("Beamly-Range-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }

        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-copyts",
                         "-ss", String(preroll), "-seek_timestamp", "1", "-t", String(end - preroll), "-i", input.path,
                         "-map_chapters", "-1", "-c", "copy", "-sn", "-dn"]
        if let track = request.audioTrack {
            // The audio-only initialization already contains the offset to the common video clock.
            let trim = "noise=amount=0:drop=lt(pts*tb\\,\(segment.start - 0.000_001))+gte(pts*tb\\,\(segment.end - 0.000_001))"
            arguments += ["-map", "0:\(track)", "-bsf:a", trim]
        } else {
            arguments += ["-map", "0:V:0", "-tag:v", isHEVC ? "hvc1" : "avc1"]
        }
        if request.isPreview {
            let filter = "noise=amount=0:drop=not(key)+lt(pts*tb\\,\(segment.start - 0.000_001))+gte(pts*tb\\,\(segment.start + 0.001)),setts=ts=PTS:duration=\(segment.duration)/TB"
            arguments += ["-bsf:v", filter]
        } else if request.audioTrack == nil {
            let decode = isHEVC || audioTrack != nil || !audio.isEmpty
                ? try await tools.videoDecodeRange(url: input, preroll: preroll, start: segment.start,
                    end: segment.end, endsAtKeyframe: request.index < video.count - 1)
                : (segment.start, segment.end)
            // HEVC pictures can be presented across a cut, so match the sequential muxer's decode boundaries.
            let usesDecodeClock = isHEVC || !audio.isEmpty
            let (lower, upper) = usesDecodeClock ? decode : (segment.start, segment.end)
            let clock = usesDecodeClock ? "dts" : "pts"
            let filter = isHEVC ? "hevc_mp4toannexb," : ""
            arguments += ["-bsf:v", filter + "noise=amount=0:drop=lt(\(clock)*tb\\,\(lower - 0.000_001))+gte(\(clock)*tb\\,\(upper - 0.000_001))"]
            if let audioTrack {
                // Use the video decode boundaries so adjacent fragments contain consecutive audio packets.
                let trim = "noise=amount=0:drop=lt(pts*tb\\,\(decode.0 - 0.000_001))+gte(pts*tb\\,\(decode.1 - 0.000_001))"
                // The shared HLS initialization already accounts for the first audio packet's offset.
                arguments += ["-map", "0:\(audioTrack)", "-bsf:a", trim + ",setts=ts=PTS-\(firstAudioPTS)/TB"]
            }
        }
        // Audio's shared initialization already applies the movie's origin to the fragment decode time.
        let offset = request.isPreview || request.audioTrack != nil ? 0 : firstPTS
        arguments += ["-output_ts_offset", String(offset), "-avoid_negative_ts", "disabled", "-f", "mp4",
                      "-movflags", "+delay_moov+dash+frag_discont+skip_trailer",
                      "-use_editlist", "0", "-frag_duration", "30000000", "-fragment_index", String(request.index + 1),
                      "range.mp4"]
        _ = try await ProcessRunner().run(executable: ffmpeg, arguments: arguments, directory: work)
        let mp4 = work.appendingPathComponent("range.mp4")
        let timestamp = request.audioTrack == nil ? try await tools.firstVideoTimestamp(url: mp4) : try await tools.firstAudioTimestamp(url: mp4)
        guard abs(timestamp - segment.start - offset) <= 0.004 else { throw CocoaError(.fileReadCorruptFile) }
        let fragment = work.appendingPathComponent("range.m4s")
        let copying = Task.detached { try Self.copyFragment(from: mp4, to: fragment) }
        try await withTaskCancellationHandler { try await copying.value } onCancel: { copying.cancel() }
        try Task.checkCancellation()
        guard !cancelled, !available(segment.name) else { return }
        // Linking publishes the first complete version without changing bytes already served at this URL.
        let destination = directory.appendingPathComponent(segment.name)
        do { try FileManager.default.linkItem(at: fragment, to: destination) }
        catch {
            if !FileManager.default.fileExists(atPath: destination.path) { throw error }
        }
    }

    static func prepareSilentAudio(for rendition: IndexedHLSAudio, initialization: String, ffmpeg: URL, directory: URL) async throws {
        guard let padding = rendition.padding else { return }
        let original = try await ac3Format(in: directory.appendingPathComponent(initialization))
        let work = directory.appendingPathComponent(".inputs")
        let template = work.appendingPathComponent("silence-\(rendition.track.id).ac3")
        defer { try? FileManager.default.removeItem(at: template) }
        _ = try await ProcessRunner().run(executable: ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
            "-t", "6", "-c:a", "ac3", "-b:a", String(padding.bitrate), "-f", "ac3", template.path
        ])
        let bytes = try Data(contentsOf: template)
        let frameSize = padding.bitrate / 250
        for (index, segment) in padding.segments.enumerated() {
            try Task.checkCancellation()
            let count = Int((segment.duration / 0.032).rounded()) * frameSize
            guard count > 0, count <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            let audio = work.appendingPathComponent("silence-\(segment.name).ac3")
            let movie = audio.appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: audio); try? FileManager.default.removeItem(at: movie) }
            try bytes.prefix(count).write(to: audio)
            _ = try await ProcessRunner().run(executable: ffmpeg, arguments: [
                "-v", "error", "-nostdin", "-f", "ac3", "-i", audio.path, "-c:a", "copy",
                "-output_ts_offset", String(segment.start), "-avoid_negative_ts", "disabled", "-f", "mp4",
                "-movflags", "+delay_moov+dash+frag_discont+skip_trailer", "-use_editlist", "0",
                "-fragment_index", String(rendition.segments.count + index + 1), movie.path
            ])
            if index == 0, try await ac3Format(in: movie) != original { throw CocoaError(.fileReadCorruptFile) }
            try copyFragment(from: movie, to: directory.appendingPathComponent(segment.name))
        }
    }

    private nonisolated static func ac3Format(in url: URL) async throws -> Data {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        guard let track = tracks.first, let format = try await track.load(.formatDescriptions).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var size = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size), size > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Data(bytes: cookie, count: size)
    }

    private nonisolated static func copyFragment(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        var offset: UInt64 = 0
        // The FFmpeg output contains a small initialization section followed by movie fragments.
        while offset < min(size, 1_048_576) {
            try input.seek(toOffset: offset)
            guard let header = try input.read(upToCount: 8), header.count == 8 else { break }
            if header.suffix(4).elementsEqual("sidx".utf8) || header.suffix(4).elementsEqual("moof".utf8) {
                try input.seek(toOffset: offset)
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: data)
                }
                return
            }
            let boxSize = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard boxSize >= 8, boxSize <= size - offset else { break }
            offset += boxSize
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
