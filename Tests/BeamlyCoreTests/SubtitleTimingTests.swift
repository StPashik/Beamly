import XCTest
@testable import BeamlyCore

final class SubtitleTimingTests: XCTestCase {
    @MainActor
    func testTextAndBitmapTimingAfterSeekWithoutMovingAudio() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL else { throw XCTSkip("FFmpeg is required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-caption-clock-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("movie.mkv")
        let subtitle = folder.appendingPathComponent("movie 'quoted:caption.srt")
        let bitmap = folder.appendingPathComponent("captions.sup")
        let job = HLSJob(tools: tools)
        defer { job.stop(); try? FileManager.default.removeItem(at: folder) }
        try "1\n00:00:02,000 --> 00:00:03,000\nTIMING\n".write(to: subtitle, atomically: true, encoding: .utf8)
        try bitmapCaptions().write(to: bitmap)
        _ = try run(ffmpeg, ["-v", "error", "-y", "-copyts", "-f", "lavfi", "-i", "color=c=black:size=160x90:rate=10:duration=8",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=8,volume=0:enable='lt(t,4)'", "-f", "sup", "-i", bitmap.path,
            "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "libx264", "-g", "10", "-bf", "0", "-c:a", "aac", "-c:s", "copy", input.path])
        let info = try await tools.probe(url: input)
        let bitmapID = try XCTUnwrap(info.subtitleTracks.first?.id)
        for start in [0.5, 1.5, 3.5] {
            for choice in [SubtitleChoice.external(subtitle), .embedded(bitmapID)] {
                var referenceClock: (container: Double, video: Double)?
                for delay in [0.0, -1.0, 1.0] {
                    let audioDelay = start == 1.5 ? delay / 2 : 0
                    let playlist = try await job.start(input: input, info: info, audioTrack: nil, subtitle: choice,
                        startTime: start, hardwareEncoding: false, preserveQuality: false, subtitleDelay: delay, audioDelay: audioDelay)
                    let deadline = Date().addingTimeInterval(15)
                    while !(try String(contentsOf: playlist, encoding: .utf8).contains("#EXT-X-ENDLIST")), Date() < deadline {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    XCTAssertTrue(try String(contentsOf: playlist, encoding: .utf8).contains("#EXT-X-ENDLIST"))
                    let video = try run(ffmpeg, ["-v", "error", "-i", playlist.path, "-map", "0:v:0", "-an", "-fps_mode", "passthrough", "-pix_fmt", "gray", "-f", "rawvideo", "-"])
                    let frameSize = 160 * 90
                    XCTAssertEqual(video.count % frameSize, 0)
                    let visible = (0..<(video.count / frameSize)).filter { index in
                        video[(index * frameSize)..<((index + 1) * frameSize)].contains { $0 > 64 }
                    }
                    if 3 + delay <= start {
                        XCTAssertTrue(visible.isEmpty, "Expired captions must not reappear after seek")
                    } else {
                        XCTAssertEqual(Double(try XCTUnwrap(visible.first)), max(0, (2 + delay - start) * 10), accuracy: 1, "start=\(start), delay=\(delay), choice=\(choice)")
                        XCTAssertEqual(Double(try XCTUnwrap(visible.last)), (3 + delay - start) * 10 - 1, accuracy: 1, "start=\(start), delay=\(delay), choice=\(choice)")
                    }
                    let audio = try run(ffmpeg, ["-v", "error", "-i", playlist.path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "8000", "-f", "f32le", "-"])
                    let samples = audio.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    // AAC re-encoding can change samples; test the transient and tone against the source clock.
                    let onset = Double(try XCTUnwrap(samples.firstIndex { abs($0) > 0.01 })) / 8000
                    XCTAssertEqual(onset, 4 - start + audioDelay, accuracy: 0.06, "start=\(start), delay=\(delay), choice=\(choice)")
                    XCTAssertEqual(Double(samples.count) / 8000, info.duration - start + min(0, audioDelay), accuracy: 0.1)
                    let tone = Array(samples.dropFirst(Int((4 - start + audioDelay + 0.2) * 8000)).prefix(4000))
                    let crossings = zip(tone, tone.dropFirst()).filter { ($0.0 >= 0) != ($0.1 >= 0) }.count
                    XCTAssertEqual(Double(crossings) * 8000 / Double(tone.count) / 2, 880, accuracy: 15)
                    let output = try await tools.probe(url: playlist)
                    let firstVideo = try await tools.firstVideoTimestamp(url: playlist)
                    if let referenceClock {
                        XCTAssertEqual(output.startTime, referenceClock.container, accuracy: 0.001)
                        XCTAssertEqual(firstVideo, referenceClock.video, accuracy: 0.001)
                    } else { referenceClock = (output.startTime, firstVideo) }
                    XCTAssertEqual(output.width, 160)
                    XCTAssertEqual(output.height, 90)
                }
            }
        }
        do {
            _ = try await job.start(input: input, info: info, audioTrack: nil, subtitle: .external(subtitle),
                startTime: 0, hardwareEncoding: false, subtitleDelay: .nan)
            XCTFail("Nonfinite subtitle timing must be rejected")
        } catch MediaPipelineError.invalidMedia { }
        XCTAssertEqual(try String(contentsOf: subtitle, encoding: .utf8), "1\n00:00:02,000 --> 00:00:03,000\nTIMING\n")
    }

    private func bitmapCaptions() -> Data {
        func bytes(_ value: Int, _ count: Int) -> [UInt8] {
            (0..<count).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
        }
        func packet(_ time: Int, _ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
            [0x50, 0x47] + bytes(time * 90_000, 4) + bytes(0, 4) + [type] + bytes(payload.count, 2) + payload
        }
        func composition(_ count: UInt8, _ number: Int, _ state: UInt8) -> [UInt8] {
            bytes(160, 2) + bytes(90, 2) + [0x10] + bytes(number, 2) + [state, 0, 0, count] +
                (count == 0 ? [] : bytes(0, 2) + [0, 0] + bytes(10, 2) + bytes(70, 2))
        }
        // A generated PGS white rectangle, visible from 2 to 3 seconds; no film data is used.
        let row: [UInt8] = Array(repeating: 1, count: 60) + [0, 0]
        let pixels = (0..<10).flatMap { _ in row }
        var data = packet(2, 0x16, composition(1, 0, 0x80))
        data += packet(2, 0x17, [1, 0] + bytes(0, 2) + bytes(0, 2) + bytes(160, 2) + bytes(90, 2))
        data += packet(2, 0x14, [0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255])
        var object = bytes(0, 2) + [0, 0xc0]
        object += bytes(pixels.count + 4, 3)
        object += bytes(60, 2) + bytes(10, 2) + pixels
        data += packet(2, 0x15, object)
        data += packet(2, 0x80, []) + packet(3, 0x16, composition(0, 1, 0)) + packet(3, 0x80, [])
        return Data(data)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-nostdin"] + arguments
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
