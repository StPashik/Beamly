import XCTest
@testable import BeamlyCore

final class HEVCStreamingTests: XCTestCase {
    func testHEVCCodecStringUsesInitializationRecordBits() throws {
        var record = Data([1, 2, 0x20, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 153] + Array(repeating: 0, count: 10))
        XCTAssertEqual(try HLSCodec.hevc(record), "hvc1.2.4.L153.B0")
        record[1] = 0x62
        record[7] = 1
        XCTAssertEqual(try HLSCodec.hevc(record), "hvc1.A2.4.H153.B0.01")
        XCTAssertThrowsError(try HLSCodec.hevc(Data()))
    }

    func testHDRProfilesAndDolbyVisionAreNotSilentlyDowngraded() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","profile":"Main 10","pix_fmt":"yuv420p10le","level":153,"width":3840,"height":2160,"avg_frame_rate":"24000/1001","color_transfer":"smpte2084","color_primaries":"bt2020","color_space":"bt2020nc"}],"format":{"duration":"120","start_time":"0.021"}}"#
        var info = try FFmpegTools.decodeProbe(Data(json.utf8))
        XCTAssertTrue(info.canCopyVideo)
        XCTAssertTrue(info.isHDR)
        XCTAssertEqual(info.videoRange, "PQ")
        XCTAssertEqual(info.frameRate, 23.976, accuracy: 0.001)
        XCTAssertEqual(info.startTime, 0.021)
        info.colorTransfer = "arib-std-b67"
        XCTAssertEqual(info.videoRange, "HLG")
        XCTAssertTrue(info.canCopyVideo)
        info.frameRate = 60
        XCTAssertFalse(info.canCopyVideo)
        info.frameRate = 24
        info.pixelFormat = "yuv422p10le"
        XCTAssertFalse(info.canCopyVideo)
        let dv = json.replacingOccurrences(of: "\"level\":153", with: "\"level\":153,\"side_data_list\":[{\"side_data_type\":\"DOVI configuration record\"}]")
        let dolby = try FFmpegTools.decodeProbe(Data(dv.utf8))
        XCTAssertTrue(dolby.hasDolbyVision)
        XCTAssertFalse(dolby.canCopyVideo)
    }

    func testWebVTTRetainsOverlappingCuesAndRetimesAfterSeek() throws {
        let text = "WEBVTT\n\n1\n00:00.500 --> 00:04.000\nOverlap\n\n2\n00:05.000 --> 00:06.000 align:start\nLater\n\n3\n00:00.000 --> 00:01.000\nOld\n"
        let shifted = try WebVTTCaptions.retimed(text, offset: 2, duration: 5)
        XCTAssertTrue(shifted.contains("X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0"))
        XCTAssertTrue(shifted.contains("00:00:00.000 --> 00:00:02.000\nOverlap"))
        XCTAssertTrue(shifted.contains("00:00:03.000 --> 00:00:04.000 align:start"))
        XCTAssertFalse(shifted.contains("Old"))
        XCTAssertThrowsError(try WebVTTCaptions.retimed("bad", offset: 0, duration: 1))
        XCTAssertThrowsError(try WebVTTCaptions.retimed("WEBVTT\n\n00:99.000 --> 00:01.000\nx", offset: 0, duration: 1))
        let delayed = try WebVTTCaptions.retimed(text, offset: -1.5, duration: 6)
        XCTAssertTrue(delayed.contains("00:00:02.000 --> 00:00:05.500\nOverlap"))
        XCTAssertFalse(delayed.contains("Later"), "Cues shifted beyond the movie are omitted")
        XCTAssertThrowsError(try WebVTTCaptions.retimed(text, offset: .nan, duration: 5))
        XCTAssertThrowsError(try WebVTTCaptions.retimed(text, offset: 0, duration: 1e100))
    }

    @MainActor
    func testReal4KHDRCopySeekAudioSubtitlesAndHTTP() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL, let ffprobe = tools.ffprobeURL else { throw XCTSkip("FFmpeg is required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-4k-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("4K 'HDR: [original].mkv")
        let captions = folder.appendingPathComponent("captions 'quoted.srt")
        try "1\n00:00:00,500 --> 00:00:05,000\nOverlapping cue\n\n2\n00:00:06,000 --> 00:00:07,000\nLater cue\n".write(to: captions, atomically: true, encoding: .utf8)
        let job = HLSJob(tools: tools)
        let server = MediaHTTPServer()
        defer { job.stop(); server.stop(); try? FileManager.default.removeItem(at: folder) }
        // libx265 is a fixture generator, not a dependency of the shipped remux player.
        let generator = try XCTUnwrap(FFmpegTools().ffmpegURL)
        _ = try run(generator, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=192x108:rate=24:duration=8,scale=3840:2160:flags=neighbor",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=8,volume=0:enable='lt(t,4)'", "-f", "lavfi", "-i", "sine=frequency=880:duration=8,volume=0:enable='lt(t,4)'", "-i", captions.path,
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le",
            "-x265-params", "pools=2:frame-threads=2:keyint=48:min-keyint=48:scenecut=0:open-gop=1:log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400",
            "-c:a:0", "aac", "-ac:a:0", "2", "-c:a:1", "ac3", "-ac:a:1", "6", "-c:s", "srt", input.path])
        let info = try await tools.probe(url: input)
        XCTAssertEqual(info.width, 3840)
        XCTAssertEqual(info.pixelFormat, "yuv420p10le")
        XCTAssertTrue(info.canCopyVideo)
        let master = try await job.start(input: input, info: info, audioTrack: 2, subtitle: .embedded(3), startTime: 0, hardwareEncoding: false, audioDelay: 0.5)
        XCTAssertTrue(job.isVideoCopied)
        let directory = master.deletingLastPathComponent()
        try await waitForEnd(directory.appendingPathComponent("stream_0.m3u8"))
        let playlist = try String(contentsOf: master, encoding: .utf8)
        XCTAssertTrue(playlist.contains("VIDEO-RANGE=PQ"))
        XCTAssertTrue(playlist.contains("RESOLUTION=3840x2160"))
        XCTAssertTrue(playlist.contains("hvc1.2."), playlist)
        XCTAssertTrue(playlist.contains("ac-3"))
        XCTAssertTrue(playlist.contains("CHANNELS=\"6\""))
        XCTAssertTrue(playlist.contains("mp4a.40.2"))
        let video = directory.appendingPathComponent("stream_0.m3u8")
        let output = try await tools.probe(url: video)
        XCTAssertEqual(output.width, info.width)
        XCTAssertEqual(output.height, info.height)
        XCTAssertEqual(output.pixelFormat, info.pixelFormat)
        XCTAssertEqual(output.colorTransfer, info.colorTransfer)
        XCTAssertEqual(output.colorPrimaries, info.colorPrimaries)
        XCTAssertEqual(output.colorSpace, info.colorSpace)
        let hashes = try [input, video].map { try frameHashes($0, ffmpeg: ffmpeg) }
        XCTAssertEqual(hashes[0].count, 192)
        XCTAssertTrue(hashes[0] == hashes[1], "Every decoded 4K frame must remain identical")
        let sei = try [input, video].map { url -> [[String: Any]] in
            let data = Data(try run(ffprobe, ["-v", "error", "-select_streams", "V:0", "-read_intervals", "0%+#1", "-show_frames", "-show_entries", "frame=side_data_list", "-of", "json", url.path]).utf8)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let frames = try XCTUnwrap(root["frames"] as? [[String: Any]])
            return (frames.first?["side_data_list"] as? [[String: Any]] ?? []).filter { ($0["side_data_type"] as? String)?.contains("Mastering") == true || ($0["side_data_type"] as? String)?.contains("Content light") == true }
        }
        XCTAssertEqual(sei[0].count, 2)
        XCTAssertTrue(NSArray(array: sei[0]).isEqual(to: sei[1]), "HDR static metadata must survive remuxing")
        func sound(_ index: Int) throws -> [String: Any] {
            let json = try run(ffprobe, ["-v", "error", "-show_entries", "stream=codec_name,channels", "-of", "json", directory.appendingPathComponent("stream_\(index).m3u8").path])
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return try XCTUnwrap((root["streams"] as? [[String: Any]])?.first)
        }
        XCTAssertEqual(try sound(2)["codec_name"] as? String, "ac3")
        XCTAssertEqual(try sound(2)["channels"] as? Int, 6)
        XCTAssertEqual(try sound(1)["channels"] as? Int, 2)
        func frequency(_ directory: URL, _ index: Int) throws -> Double {
            let data = try runData(ffmpeg, ["-v", "error", "-i", directory.appendingPathComponent("stream_\(index).m3u8").path,
                "-map", "0:a:0", "-ss", "4.5", "-t", "1", "-ac", "1", "-ar", "8000", "-f", "f32le", "-"])
            let samples = data.withUnsafeBytes { bytes in
                stride(from: 0, to: data.count - 3, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
            }
            let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            return Double(crossings) / (Double(samples.count) / 8000)
        }
        XCTAssertEqual(try frequency(directory, 1), 880, accuracy: 15)
        XCTAssertEqual(try frequency(directory, 2), 880, accuracy: 15)
        func onset(_ url: URL, stream: String) throws -> Double {
            let first = try run(ffprobe, ["-v", "error", "-select_streams", stream, "-read_intervals", "%+#1", "-show_entries", "packet=pts_time", "-of", "json", url.path])
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
            let timestamp = (root["packets"] as? [[String: Any]])?.first?["pts_time"] as? String
            let pts = try XCTUnwrap(timestamp.flatMap(Double.init))
            let data = try runData(ffmpeg, ["-v", "error", "-i", url.path, "-map", "0:\(stream)", "-ac", "1", "-ar", "8000", "-f", "f32le", "-"])
            let samples = data.withUnsafeBytes { bytes in stride(from: 0, to: data.count - 3, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) } }
            let sample = try XCTUnwrap(samples.firstIndex { abs($0) > 0.003 })
            return pts + Double(sample) / 8000
        }
        let surroundOnset = try onset(input, stream: "2")
        XCTAssertEqual(try onset(directory.appendingPathComponent("stream_2.m3u8"), stream: "a:0"), surroundOnset + 0.5 - job.sourceOffset, accuracy: 0.06)
        XCTAssertEqual(try onset(directory.appendingPathComponent("stream_1.m3u8"), stream: "a:0"), surroundOnset + 0.5 - job.sourceOffset, accuracy: 0.06)
        try await server.start()
        let url = try server.publish(directory: directory, playlist: "master.m3u8")
        for name in ["master.m3u8", "stream_0.m3u8", "init_0.mp4", "segment_0_000000.m4s", "captions.m3u8", "captions.vtt"] {
            let (data, response) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent(name))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertFalse(data.isEmpty)
        }
        let seeked = try await job.start(input: input, info: info, audioTrack: 1, subtitle: .external(captions), startTime: 3.5, hardwareEncoding: false)
        XCTAssertLessThan(job.sourceOffset, 3.5)
        XCTAssertGreaterThan(job.sourceOffset, 0, "The second GOP must map after the movie's beginning")
        let shifted = try String(contentsOf: seeked.deletingLastPathComponent().appendingPathComponent("captions.vtt"), encoding: .utf8)
        XCTAssertTrue(shifted.contains("00:00:00.000 -->"), "A cue spanning the seek must remain visible")
        XCTAssertTrue(shifted.contains("Overlapping cue"))
        XCTAssertTrue(shifted.contains("Later cue"))
        XCTAssertTrue(job.isVideoCopied)
        let seekFrames = try frameHashes(seeked.deletingLastPathComponent().appendingPathComponent("stream_0.m3u8"), ffmpeg: ffmpeg)
        XCTAssertEqual(seekFrames.count, 144)
        XCTAssertTrue(Array(hashes[0].suffix(144)) == seekFrames, "Seeking an open GOP must not corrupt or repeat video frames")
        XCTAssertEqual(try frequency(seeked.deletingLastPathComponent(), 1), 440, accuracy: 15)
        XCTAssertEqual(try onset(seeked.deletingLastPathComponent().appendingPathComponent("stream_1.m3u8"), stream: "a:0"), try onset(input, stream: "1") - job.sourceOffset, accuracy: 0.06)

        for (choice, delay) in [(SubtitleChoice.external(captions), -1.5), (.embedded(3), 1.5)] {
            let audioDelay = delay > 0 ? 0.5 : -0.5
            let shifted = try await job.start(input: input, info: info, audioTrack: 1, subtitle: choice,
                startTime: 3.5, hardwareEncoding: false, subtitleDelay: delay, audioDelay: audioDelay)
            let folder = shifted.deletingLastPathComponent()
            let lines = try String(contentsOf: folder.appendingPathComponent("captions.vtt"), encoding: .utf8).components(separatedBy: .newlines)
            let cue = try XCTUnwrap(lines.firstIndex(of: "Later cue"))
            let times = lines[cue - 1].components(separatedBy: " --> ").map { value in
                value.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
            }
            XCTAssertEqual(times[0] + job.sourceOffset, 6 + delay, accuracy: 0.03)
            XCTAssertEqual(times[1] + job.sourceOffset, min(info.duration, 7 + delay), accuracy: 0.03)
            XCTAssertTrue(job.isVideoCopied)
            XCTAssertEqual(try frameHashes(folder.appendingPathComponent("stream_0.m3u8"), ffmpeg: ffmpeg), seekFrames)
            XCTAssertEqual(try onset(folder.appendingPathComponent("stream_1.m3u8"), stream: "a:0"), try onset(input, stream: "1") + audioDelay - job.sourceOffset, accuracy: 0.06)
        }

        let hlg = folder.appendingPathComponent("HLG.mkv")
        _ = try run(ffmpeg, ["-v", "error", "-y", "-i", input.path, "-map", "0", "-c", "copy", "-bsf:v", "hevc_metadata=transfer_characteristics=18", "-color_trc", "arib-std-b67", hlg.path])
        let hlgInfo = try await tools.probe(url: hlg)
        XCTAssertEqual(hlgInfo.colorTransfer, "arib-std-b67")
        let hlgMaster = try await job.start(input: hlg, info: hlgInfo, audioTrack: 1, subtitle: .none, startTime: 0, hardwareEncoding: false)
        XCTAssertTrue(try String(contentsOf: hlgMaster, encoding: .utf8).contains("VIDEO-RANGE=HLG"))
        let hlgOutput = try await tools.probe(url: hlgMaster.deletingLastPathComponent().appendingPathComponent("stream_0.m3u8"))
        XCTAssertEqual(hlgOutput.colorTransfer, "arib-std-b67")
        XCTAssertEqual(hlgOutput.pixelFormat, "yuv420p10le")
        XCTAssertEqual(hlgOutput.width, 3840)

        let compatibility = try await job.start(input: input, info: info, audioTrack: 1, subtitle: .external(captions), startTime: 2, hardwareEncoding: false, preserveQuality: false)
        let sdr = try await tools.probe(url: compatibility.deletingLastPathComponent().appendingPathComponent("segment000000.ts"))
        XCTAssertFalse(job.isVideoCopied)
        XCTAssertEqual(sdr.videoCodec, "h264")
        XCTAssertEqual(sdr.width, 1920)
        XCTAssertEqual(sdr.height, 1080)
        XCTAssertEqual(sdr.pixelFormat, "yuv420p")
        XCTAssertEqual(sdr.colorTransfer, "bt709")
        var dolby = info
        dolby.hasDolbyVision = true
        do {
            _ = try await job.start(input: input, info: dolby, audioTrack: 1, subtitle: .none, startTime: 0, hardwareEncoding: false)
            XCTFail("Dolby Vision must not silently lose its metadata")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Dolby Vision")) }
        job.stop()
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        String(decoding: try runData(executable, arguments), as: UTF8.self)
    }

    private func frameHashes(_ url: URL, ffmpeg: URL) throws -> [String] {
        try run(ffmpeg, ["-v", "error", "-i", url.path, "-map", "0:v:0", "-an", "-pix_fmt", "yuv420p10le", "-f", "framemd5", "-"])
            .components(separatedBy: .newlines).filter { !$0.hasPrefix("#") && $0.contains(",") }
            .map { $0.split(separator: ",").last!.trimmingCharacters(in: .whitespaces) }
    }

    private func runData(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-nostdin"] + arguments.filter { $0 != "-nostdin" }
        if executable.lastPathComponent == "ffprobe" { process.arguments = arguments }
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        return data
    }

    private func waitForEnd(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if (try? String(contentsOf: url, encoding: .utf8).contains("#EXT-X-ENDLIST")) == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("HLS did not finish")
    }
}
