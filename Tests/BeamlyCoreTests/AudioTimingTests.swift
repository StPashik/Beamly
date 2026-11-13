import XCTest
@testable import BeamlyCore

final class AudioTimingTests: XCTestCase {
    @MainActor
    func testEarlyHLSPadsShortStereoDolbyWithoutChangingSourcePackets() async throws {
        let tools = mediaTestTools()
        let ffmpeg = try XCTUnwrap(tools.ffmpegURL)
        let ffprobe = try XCTUnwrap(tools.ffprobeURL)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-dolby-tail-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("movie.mkv")
        let captions = folder.appendingPathComponent("captions.srt")
        let job = HLSJob(tools: tools)
        defer { job.stop(); try? FileManager.default.removeItem(at: folder) }
        try "1\n00:00:21,000 --> 00:00:23,000\nCredits\n".write(to: captions, atomically: true, encoding: .utf8)
        _ = try run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10:duration=24.1",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=14.976",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=23.072",
            "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=16.000", "-i", captions.path,
            "-map", "0:v", "-map", "1:a", "-map", "3:a", "-map", "2:a", "-map", "4:s",
            "-c:v", "libx264", "-g", "10", "-bf", "0", "-sc_threshold", "0",
            "-c:a:0", "ac3", "-ac:a:0", "2", "-b:a:0", "384k", "-c:a:1", "eac3", "-ac:a:1", "6", "-c:a:2", "eac3", "-ac:a:2", "6",
            "-filter:a:0", "asetpts=PTS+256/SR/TB", "-filter:a:1", "asetpts=PTS+256/SR/TB",
            "-filter:a:2", "asetpts=PTS+256/SR/TB+1.024/TB", "-c:s", "srt", input.path])
        let info = try await tools.probe(url: input)
        var fallback: Error?
        let playlist = try await job.prepareEarlyHLS(input: input, info: info, audioTrack: nil, startTime: 21, subtitleDelay: 0,
            onFailure: { fallback = $0 }, progress: { _ in })
        let master = try XCTUnwrap(playlist)
        let cache = master.deletingLastPathComponent()
        XCTAssertTrue(job.isVideoCopied)
        XCTAssertTrue(job.usesOriginalDolby)
        XCTAssertEqual(Set(job.audioNames.keys), [1, 3], "A short unsupported alternate must not block the selected dub or the late-starting original")
        let credits = cache.appendingPathComponent("captions-4.vtt")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while fallback == nil, !FileManager.default.fileExists(atPath: credits.path), .now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if let fallback { throw fallback }
        XCTAssertTrue(try String(contentsOf: credits, encoding: .utf8).contains("Credits"))

        let audioPlaylist = try String(contentsOf: cache.appendingPathComponent("stream_1.m3u8"), encoding: .utf8)
        let duration = audioPlaylist.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).dropLast()) }.reduce(0, +)
        XCTAssertEqual(duration, 24.1, accuracy: 0.032)
        var audio = try Data(contentsOf: cache.appendingPathComponent("init_1.mp4"))
        for name in audioPlaylist.split(separator: "\n") where name.hasSuffix(".m4s") {
            let file = cache.appendingPathComponent(String(name))
            let fragment = FileManager.default.fileExists(atPath: file.path)
                ? file : cache.appendingPathComponent(".generated").appendingPathComponent(String(name))
            audio.append(try Data(contentsOf: fragment))
        }
        let output = folder.appendingPathComponent("padded.mp4")
        try audio.write(to: output)
        struct Packet: Decodable {
            let pts_time: String
            let data_hash: String
        }
        struct Packets: Decodable { let packets: [Packet] }
        func packets(_ movie: URL) throws -> [Packet] {
            let data = try run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_packets",
                "-show_data_hash", "sha256", "-show_entries", "packet=pts_time,data_hash", "-of", "json", movie.path])
            return try JSONDecoder().decode(Packets.self, from: data).packets
        }
        let original = try packets(input)
        let padded = try packets(output)
        XCTAssertFalse(original.isEmpty)
        XCTAssertTrue(padded.map(\.data_hash).starts(with: original.map(\.data_hash)),
                      "Padding must preserve the original AC-3 packets byte for byte")
        XCTAssertGreaterThan(padded.count, original.count)
        let times = padded.compactMap { Double($0.pts_time) }
        XCTAssertEqual(times.count, padded.count)
        XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { abs($1 - $0 - 0.032) < 0.000_001 },
                      "Every padding fragment must continue the AC-3 sample clock")
        let tail = try run(ffmpeg, ["-v", "error", "-ss", "21", "-i", output.path, "-t", "1", "-f", "s16le", "-"])
        XCTAssertFalse(tail.isEmpty)
        let peak = tail.withUnsafeBytes { bytes in
            stride(from: 0, to: tail.count - 1, by: 2)
                .map { abs(Int(bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self))) }.max() ?? Int.max
        }
        XCTAssertLessThanOrEqual(peak, 2, "Allow for the decoder's one-bit dither when rendering digital silence")
        let incomplete = try await job.prepareEarlyHLS(input: input, info: info, audioTrack: 2, subtitleDelay: 0,
            onFailure: { fallback = $0 }, progress: { _ in })
        XCTAssertNil(incomplete, "A selected track that cannot be repaired must use regular preparation")
    }

    @MainActor
    func testAudioShiftRetainsVideoClockAcrossSeekAndConversion() async throws {
        let tools = mediaTestTools()
        let ffmpeg = try XCTUnwrap(tools.ffmpegURL)
        let ffprobe = try XCTUnwrap(tools.ffprobeURL)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-audio-clock-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("movie.mkv")
        let caption = folder.appendingPathComponent("captions.srt")
        let job = HLSJob(tools: tools)
        defer { job.stop(); try? FileManager.default.removeItem(at: folder) }
        try "1\n00:00:04,000 --> 00:00:07,000\nUNCHANGED CLOCK\n".write(to: caption, atomically: true, encoding: .utf8)
        _ = try run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10:duration=12",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=12,volume=0:enable='lt(t,8)'",
            "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-g", "10", "-bf", "0", "-c:a", "aac", input.path])
        let original = try Data(contentsOf: input)
        let info = try await tools.probe(url: input)
        for preserve in [true, false] {
            for start in [0.0, 3.5] {
                var referenceVideo: Data?
                for delay in [0.0, -1.0, 1.0] {
                    let playlist = try await job.start(input: input, info: info, audioTrack: nil, subtitle: .external(caption),
                        startTime: start, hardwareEncoding: false, preserveQuality: preserve, subtitleDelay: 0.5, audioDelay: delay)
                    let directory = playlist.deletingLastPathComponent()
                    let video = preserve ? directory.appendingPathComponent("stream_0.m3u8") : playlist
                    try await waitForEnd(video)
                    let firstVideo = try await tools.firstVideoTimestamp(url: video)
                    let frames = try run(ffmpeg, ["-v", "error", "-i", video.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-pix_fmt", "gray", "-f", "rawvideo", "-"])
                    if let referenceVideo { XCTAssertEqual(frames, referenceVideo, "Audio timing must not alter video or subtitle frames") }
                    else { referenceVideo = frames }
                    if preserve {
                        let text = try String(contentsOf: directory.appendingPathComponent("captions.vtt"), encoding: .utf8)
                        let line = try XCTUnwrap(text.components(separatedBy: .newlines).first { $0.contains(" --> ") })
                        let times = line.components(separatedBy: " --> ").map { value in
                            value.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
                        }
                        XCTAssertEqual(times[0] + job.sourceOffset, 4.5, accuracy: 0.002)
                        XCTAssertEqual(times[1] + job.sourceOffset, 7.5, accuracy: 0.002)
                    }
                    let audio = preserve ? directory.appendingPathComponent("stream_1.m3u8") : playlist
                    let data = try run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-read_intervals", "%+#1", "-show_entries", "packet=pts_time", "-of", "json", audio.path])
                    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let pts = try XCTUnwrap(((root["packets"] as? [[String: Any]])?.first?["pts_time"] as? String).flatMap(Double.init))
                    let pcm = try run(ffmpeg, ["-v", "error", "-i", audio.path, "-map", "0:a:0", "-ac", "1", "-ar", "8000", "-f", "f32le", "-"])
                    let samples = pcm.withUnsafeBytes { bytes in
                        stride(from: 0, to: pcm.count - 3, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
                    }
                    let onset = pts + Double(try XCTUnwrap(samples.firstIndex { abs($0) > 0.01 })) / 8000
                    let origin = preserve ? job.sourceOffset : job.sourceOffset - firstVideo
                    XCTAssertEqual(onset + origin, 8 + delay, accuracy: 0.08, "copy=\(preserve), start=\(start), delay=\(delay)")
                    XCTAssertLessThanOrEqual(pts + Double(samples.count) / 8000 + origin, info.duration + 0.08, "Delayed audio must not extend the movie")
                    let tone = Array(samples.suffix(4000))
                    let crossings = zip(tone, tone.dropFirst()).filter { ($0.0 >= 0) != ($0.1 >= 0) }.count
                    XCTAssertEqual(Double(crossings) * 8000 / Double(tone.count) / 2, 880, accuracy: 20)
                }
            }
        }
        for preserve in [true, false] {
            let playlist = try await job.start(input: input, info: info, audioTrack: nil, subtitle: .none,
                startTime: 11, hardwareEncoding: false, preserveQuality: preserve, audioDelay: -10)
            let output = try await tools.probe(url: playlist)
            XCTAssertTrue(output.audioTracks.isEmpty, "Seeking past shifted audio must keep the remaining silent video playable")
        }
        let short = folder.appendingPathComponent("short.mkv")
        _ = try run(ffmpeg, ["-v", "error", "-y", "-i", input.path, "-t", "2", "-c", "copy", short.path])
        let shortInfo = try await tools.probe(url: short)
        for preserve in [true, false] {
            for delay in [-10.0, 10.0] {
                let playlist = try await job.start(input: short, info: shortInfo, audioTrack: nil, subtitle: .none,
                    startTime: 0, hardwareEncoding: false, preserveQuality: preserve, audioDelay: delay)
                let output = try await tools.probe(url: playlist)
                XCTAssertTrue(output.audioTracks.isEmpty, "A correction longer than a short clip must produce playable silent video")
            }
        }
        for delay in [Double.nan, .infinity, 11, -11] {
            do {
                _ = try await job.start(input: input, info: info, audioTrack: nil, subtitle: .none, startTime: 0, hardwareEncoding: false, audioDelay: delay)
                XCTFail("Invalid audio corrections must be rejected")
            } catch MediaPipelineError.invalidMedia { }
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    private func waitForEnd(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(try String(contentsOf: url, encoding: .utf8).contains("#EXT-X-ENDLIST")), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("#EXT-X-ENDLIST"))
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        return data
    }
}
