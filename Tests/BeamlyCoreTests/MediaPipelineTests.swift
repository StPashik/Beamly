import XCTest
@testable import BeamlyCore

final class MediaPipelineTests: XCTestCase {
    func testBundledToolsTakePriorityOverHomebrewAndRetainCustomOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-tools-\(UUID())")
        let app = root.appendingPathComponent("Fixture.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        let custom = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>app.beamly.tools-fixture</string></dict></plist>".utf8)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        for directory in [helpers, custom] {
            for name in ["ffmpeg", "ffprobe"] {
                let file = directory.appendingPathComponent(name)
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(FFmpegTools(bundle: bundle).ffmpegURL, helpers.appendingPathComponent("ffmpeg"))
        XCTAssertEqual(FFmpegTools(bundle: bundle).ffprobeURL, helpers.appendingPathComponent("ffprobe"))
        XCTAssertEqual(FFmpegTools(customDirectory: custom, bundle: bundle).ffmpegURL, custom.appendingPathComponent("ffmpeg"))
    }

    func testProbeKeepsGlobalTrackIndicesAndIgnoresCoverArt() throws {
        let data = Data(#"{"streams":[{"index":0,"codec_type":"video","codec_name":"mjpeg","width":100,"height":100,"disposition":{"attached_pic":1}},{"index":1,"codec_type":"video","codec_name":"hevc","width":1920,"height":1080,"duration":"42.5"},{"index":2,"codec_type":"audio","codec_name":"aac","channels":6,"tags":{"language":"rus","title":"Дубляж"}},{"index":4,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng"}}],"format":{"duration":"N/A"}}"#.utf8)
        let info = try FFmpegTools.decodeProbe(data)
        XCTAssertEqual(info.duration, 42.5)
        XCTAssertEqual(info.videoCodec, "hevc")
        XCTAssertEqual(info.width, 1920)
        XCTAssertEqual(info.audioTracks.first?.id, 2)
        XCTAssertEqual(info.audioTracks.first?.channels, 6)
        XCTAssertEqual(info.audioTracks.first?.language, "rus")
        XCTAssertEqual(info.subtitleTracks.first?.id, 4)
    }

    func testProbeRejectsAudioOnlyAndNonfiniteDurations() throws {
        XCTAssertThrowsError(try FFmpegTools.decodeProbe(Data(#"{"streams":[{"index":0,"codec_type":"audio"}]}"#.utf8)))
        let info = try FFmpegTools.decodeProbe(Data(#"{"streams":[{"index":0,"codec_type":"video"}],"format":{"duration":"inf"}}"#.utf8))
        XCTAssertEqual(info.duration, 0)
    }

    func testChapterMetadataValidatesRangesAndKeepsOlderMetadataDecodable() throws {
        let data = Data(#"{"streams":[{"index":0,"codec_type":"video"}],"format":{"duration":"10"},"chapters":[{"start_time":"5","end_time":"20","tags":{"title":"  Finale  "}},{"start_time":"0","end_time":"5","tags":{"title":"  "}},{"start_time":"-1","end_time":"2"},{"start_time":"NaN","end_time":"3"},{"start_time":"2","end_time":"Infinity"},{"start_time":"4","end_time":"3"},{"start_time":"10","end_time":"12"},{"end_time":"3"}]}"#.utf8)
        let info = try FFmpegTools.decodeProbe(data)
        let chapters = try XCTUnwrap(info.chapters)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters.map(\.start), [0, 5])
        XCTAssertEqual(chapters.map(\.end), [5, 10])
        XCTAssertNil(chapters[0].title)
        XCTAssertEqual(chapters[1].title, "Finale")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        legacy.removeValue(forKey: "chapters")
        XCTAssertNil(try JSONDecoder().decode(MediaInfo.self, from: JSONSerialization.data(withJSONObject: legacy)).chapters)
    }

    @MainActor
    func testH264AirPlayPreviewsCopyKeyframesOnTheVideoTimeline() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL, let ffprobe = tools.ffprobeURL else { throw XCTSkip("FFmpeg is required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-iframes-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("source.mkv")
        let job = HLSJob(tools: tools)
        defer { job.stop(); try? FileManager.default.removeItem(at: folder) }

        func run(_ executable: URL, _ arguments: [String]) throws -> Data {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            try process.run()
            try? output.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return data
        }

        _ = try run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=12:duration=5.4",
                             "-c:v", "libx264", "-g", "12", "-sc_threshold", "0", input.path])
        let info = try await tools.probe(url: input)
        let master = try await job.start(input: input, info: info, audioTrack: nil, subtitle: .none,
                                         startTime: 1.5, hardwareEncoding: false)
        let cache = master.deletingLastPathComponent()
        let video = cache.appendingPathComponent("stream_0.m3u8")
        let previews = cache.appendingPathComponent("iframe.m3u8")
        let multivariant = try String(contentsOf: master, encoding: .utf8)
        let variant = try XCTUnwrap(multivariant.split(separator: "\n").first { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") })
        XCTAssertTrue(variant.contains("CODECS=\"avc1."))
        XCTAssertTrue(variant.contains("VIDEO-RANGE=SDR,URI=\"iframe.m3u8\""))
        let playlist = try String(contentsOf: previews, encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXT-X-I-FRAMES-ONLY"))
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"iframe-init.mp4\""))
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))
        func duration(_ text: String) -> Double {
            text.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
                .compactMap { Double($0.dropFirst(8).dropLast()) }.reduce(0, +)
        }
        XCTAssertEqual(duration(playlist), try duration(String(contentsOf: video, encoding: .utf8)), accuracy: 0.000001)

        struct Packets: Decodable {
            struct Packet: Decodable {
                let pts_time: String
                let flags: String
                let data_hash: String
            }
            let packets: [Packet]
        }
        func packets(_ file: URL) throws -> [Packets.Packet] {
            let data = try run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_packets", "-show_data_hash", "SHA256",
                                         "-show_entries", "packet=pts_time,flags,data_hash", "-of", "json", file.path])
            let result = try JSONDecoder().decode(Packets.self, from: data)
            return result.packets
        }
        let keys = try packets(video).filter { $0.flags.contains("K") }
        let frames = try packets(previews)
        XCTAssertGreaterThan(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0.flags.contains("K") })
        XCTAssertEqual(frames.map(\.data_hash), keys.map(\.data_hash))
        let firstPTS = try XCTUnwrap(keys.first.flatMap { Double($0.pts_time) })
        for (frame, key) in zip(frames, keys) {
            XCTAssertEqual(try XCTUnwrap(Double(frame.pts_time)), try XCTUnwrap(Double(key.pts_time)) - firstPTS, accuracy: 0.001)
        }

        // A stream with one remaining keyframe still plays, with no incomplete preview rendition.
        let tail = try await job.start(input: input, info: info, audioTrack: nil, subtitle: .none,
                                       startTime: 5.1, hardwareEncoding: false)
        XCTAssertFalse(try String(contentsOf: tail, encoding: .utf8).contains("#EXT-X-I-FRAME-STREAM-INF:"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tail.deletingLastPathComponent().appendingPathComponent("iframe-init.mp4").path))
    }

    @MainActor
    func testAV1InputCanUseSoftwareH264CompatibilityConversion() async throws {
        let tools = mediaTestTools()
        guard let generator = FFmpegTools().ffmpegURL, tools.ffmpegURL != nil else { throw XCTSkip("FFmpeg is required") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-av1-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("source.mkv")
        let job = HLSJob(tools: tools)
        defer { job.stop(); try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = generator
        process.arguments = ["-v", "error", "-nostdin", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10:duration=2",
            "-c:v", "libaom-av1", "-cpu-used", "8", "-threads", "2", "-crf", "40", input.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let info = try await tools.probe(url: input)
        XCTAssertEqual(info.videoCodec, "av1")
        var stages: [PlaybackPreparationStage] = []
        let output = try await job.start(input: input, info: info, audioTrack: nil, subtitle: .none,
                                         startTime: 0, hardwareEncoding: false, preserveQuality: false) { stages.append($0) }
        XCTAssertEqual(stages, [.softwareEncoding])
        let converted = try await tools.probe(url: output)
        XCTAssertEqual(converted.videoCodec, "h264")
        XCTAssertEqual(converted.width, 160)
        XCTAssertEqual(converted.height, 90)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    @MainActor
    func testHLSPreservesExplicitAudioAndSubtitleTimingAfterSeek() {
        let url = URL(fileURLWithPath: "/tmp/a'quote:comma,file.mkv")
        let info = MediaInfo(duration: 100, width: 1920, height: 1080, videoCodec: "h264", audioTracks: [MediaTrack(id: 3, codec: "aac")])
        let arguments = HLSJob.arguments(input: url, info: info, audioTrack: 7, subtitleRendering: .text("subtitles=filename=.inputs/subtitle.srt"), startTime: 30, hardwareEncoding: false)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-i")! + 1], url.path)
        XCTAssertTrue(arguments.contains("0:7"))
        let filter = arguments[arguments.firstIndex(of: "-vf")! + 1]
        XCTAssertTrue(filter.contains("setpts=PTS+(30.0)/TB,subtitles=filename=.inputs/subtitle.srt,setpts=PTS-(30.0)/TB"))
        XCTAssertFalse(filter.contains(url.path))
        XCTAssertTrue(arguments.contains("independent_segments+temp_file"))
        XCTAssertTrue(arguments.contains("event"))
    }

    @MainActor
    func testBitmapSubtitlesMapTheSelectedGlobalStreamThroughOverlay() {
        let info = MediaInfo(duration: 100, width: 1920, height: 1080, videoCodec: "h264", audioTracks: [MediaTrack(id: 3, codec: "aac")])
        let arguments = HLSJob.arguments(input: URL(fileURLWithPath: "/tmp/movie.mkv"), info: info, audioTrack: nil,
                                           subtitleRendering: .bitmap(8), startTime: 30, hardwareEncoding: false)
        let graph = arguments[arguments.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(graph.contains("[0:V:0][0:8]overlay="))
        XCTAssertTrue(graph.contains("eof_action=pass:repeatlast=0"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-map")! + 1], "[rendered]")
        XCTAssertFalse(arguments.contains("-vf"))
        XCTAssertFalse(graph.contains("setpts="))
        for delay in [-1.5, 1.5] {
            let shifted = HLSJob.arguments(input: URL(fileURLWithPath: "/tmp/movie.mkv"), info: info, audioTrack: nil,
                subtitleRendering: .bitmap(8), startTime: 30, hardwareEncoding: false, subtitleDelay: delay)
            let graph = shifted[shifted.firstIndex(of: "-filter_complex")! + 1]
            XCTAssertTrue(graph.contains("[0:8]setpts=PTS+(\(delay))/TB[caption];[0:V:0][caption]overlay="))
            if delay > 0 {
                XCTAssertTrue(shifted.contains("0:3"))
                XCTAssertEqual(shifted[shifted.firstIndex(of: "-ss")! + 1], "28.5")
                XCTAssertEqual(shifted[shifted.lastIndex(of: "-ss")! + 1], "1.5")
            }
        }
    }

    @MainActor
    func testRealFFmpegPreparesSeekedHLSWithQuotedSubtitlePath() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL, tools.ffprobeURL != nil else { throw XCTSkip("FFmpeg не установлен") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-media-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("movie 'colon: [bracket],.mkv")
        let subtitle = directory.appendingPathComponent("subtitle 'colon: [bracket],.srt")
        let job = HLSJob(tools: tools)
        defer {
            job.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        try "1\n00:00:02,500 --> 00:00:04,000\nBeamly subtitle\n".write(to: subtitle, atomically: true, encoding: .utf8)
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=8",
                               "-f", "lavfi", "-i", "sine=frequency=880:duration=8", "-c:v", "libx264", "-c:a", "aac", input.path]
        generator.standardInput = FileHandle.nullDevice
        generator.standardOutput = FileHandle.nullDevice
        generator.standardError = FileHandle.nullDevice
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let info = try await tools.probe(url: input)
        XCTAssertGreaterThan(info.duration, 7)
        let playlist = try await job.start(input: input, info: info, audioTrack: info.audioTracks.first?.id,
                                          subtitle: .external(subtitle), startTime: 2, hardwareEncoding: false, preserveQuality: false)
        let text = try String(contentsOf: playlist, encoding: .utf8)
        XCTAssertTrue(text.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertTrue(text.contains("#EXT-X-ENDLIST"), "Compatibility playlists must be complete before publication")
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "#EXTINF:").count - 1, 2)
        let segment = playlist.deletingLastPathComponent().appendingPathComponent("segment000000.ts")
        let segmentInfo = try await tools.probe(url: segment)
        XCTAssertEqual(segmentInfo.videoCodec, "h264")
        XCTAssertEqual(segmentInfo.audioTracks.first?.codec, "aac")
        XCTAssertEqual(segmentInfo.width, 160)
        XCTAssertEqual(segmentInfo.height, 90)
    }
}
