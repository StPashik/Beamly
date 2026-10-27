import XCTest
@testable import BeamlyCore

final class MediaPipelineTests: XCTestCase {
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

    @MainActor
    func testHLSPreservesExplicitAudioAndSubtitleTimingAfterSeek() {
        let url = URL(fileURLWithPath: "/tmp/a'quote:comma,file.mkv")
        let info = MediaInfo(duration: 100, width: 1920, height: 1080, videoCodec: "h264", audioTracks: [MediaTrack(id: 3, codec: "aac")])
        let arguments = HLSJob.arguments(input: url, info: info, audioTrack: 7, subtitleRendering: .text("subtitles=filename=.inputs/subtitle.srt"), startTime: 30, hardwareEncoding: false)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-i")! + 1], url.path)
        XCTAssertTrue(arguments.contains("0:7"))
        let filter = arguments[arguments.firstIndex(of: "-vf")! + 1]
        XCTAssertTrue(filter.contains("setpts=PTS+30.0/TB,subtitles=filename=.inputs/subtitle.srt,setpts=PTS-30.0/TB"))
        XCTAssertFalse(filter.contains(url.path))
        XCTAssertTrue(arguments.contains("independent_segments+temp_file"))
        XCTAssertTrue(arguments.contains("event"))
    }

    @MainActor
    func testBitmapSubtitlesMapTheSelectedGlobalStreamThroughOverlay() {
        let info = MediaInfo(duration: 100, width: 1920, height: 1080, videoCodec: "h264")
        let arguments = HLSJob.arguments(input: URL(fileURLWithPath: "/tmp/movie.mkv"), info: info, audioTrack: nil,
                                           subtitleRendering: .bitmap(8), startTime: 30, hardwareEncoding: false)
        let graph = arguments[arguments.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(graph.contains("[0:V:0][0:8]overlay="))
        XCTAssertTrue(graph.contains("eof_action=pass:repeatlast=0"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-map")! + 1], "[rendered]")
        XCTAssertFalse(arguments.contains("-vf"))
        XCTAssertFalse(graph.contains("setpts="))
    }

    @MainActor
    func testRealFFmpegPreparesSeekedHLSWithQuotedSubtitlePath() async throws {
        let tools = FFmpegTools()
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
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "#EXTINF:").count - 1, 2)
        let segment = playlist.deletingLastPathComponent().appendingPathComponent("segment000000.ts")
        let segmentInfo = try await tools.probe(url: segment)
        XCTAssertEqual(segmentInfo.videoCodec, "h264")
        XCTAssertEqual(segmentInfo.audioTracks.first?.codec, "aac")
        XCTAssertEqual(segmentInfo.width, 160)
        XCTAssertEqual(segmentInfo.height, 90)
    }
}
