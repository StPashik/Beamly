import AVKit
import BeamlyCore
import Combine
import XCTest
@testable import Beamly

final class PlaybackStatusTests: XCTestCase {
    @MainActor
    func testWaitingPreparationQualityReasonsAndSoftwareRetry() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL, let ffprobe = tools.ffprobeURL else { throw XCTSkip("FFmpeg is required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-playback-status-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "app.beamly.playback-status.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoPlay")
        defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
        let video = folder.appendingPathComponent("Movie.mp4")
        let captions = folder.appendingPathComponent("captions.srt")
        try "1\n00:00:00,500 --> 00:00:05,000\nPlayback status caption\n".write(to: captions, atomically: true, encoding: .utf8)
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=blue:size=160x90:rate=24:duration=6",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-c:v", "libx264", "-c:a", "aac", "-movflags", "+faststart", video.path]
        generator.standardInput = FileHandle.nullDevice
        generator.standardOutput = FileHandle.nullDevice
        generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let player = AirPlayTestPlayer()
        let model = AppModel(stateURL: folder.appendingPathComponent("queue.json"), defaults: defaults, player: player)
        defer { model.shutdown() }
        var stages: [PlaybackPreparationStage] = []
        let observation = model.$preparationStage.sink { stages.append($0) }
        defer { observation.cancel() }
        func ready() -> Bool { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        model.add([video])
        try await wait(diagnostic: model.errorMessage ?? "") { ready() }
        XCTAssertEqual(model.playbackStatus, "Choose an AirPlay device to start playback.")
        XCTAssertEqual(model.qualityTitle, "Original video quality")
        XCTAssertEqual(model.qualityExplanation, "Direct playback without video conversion.")
        player.setExternalPlaybackActive(true)
        try await wait { model.isExternal }
        XCTAssertEqual(model.playbackStatus, "Paused")
        player.simulateTimeControl(.waitingToPlayAtSpecifiedRate, reason: .evaluatingBufferingRate)
        try await wait { model.playbackStatus == "Starting playback…" }
        XCTAssertFalse(model.isBuffering, "Brief buffer evaluation must not be reported as a stall")
        player.simulateTimeControl(.waitingToPlayAtSpecifiedRate, reason: .toMinimizeStalls)
        try await wait { model.isBuffering }
        XCTAssertTrue(model.isPlaying, "Pause remains available during buffering")
        XCTAssertEqual(model.playbackStatus, "Buffering…")
        XCTAssertEqual(model.status, "Buffering…")
        model.togglePlay()
        try await wait { !model.isPlaying && !model.isBuffering }
        XCTAssertEqual(model.playbackStatus, "Paused")
        player.simulateTimeControl(.playing)
        try await wait { model.playbackStatus == "Playing via AirPlay" }
        player.simulateTimeControl(.waitingToPlayAtSpecifiedRate, reason: .toMinimizeStalls)
        try await wait { model.isBuffering }
        player.setExternalPlaybackActive(false)
        try await wait { !model.isExternal && !model.isBuffering && !model.isPlaying }
        XCTAssertEqual(model.playbackStatus, "Choose an AirPlay device to start playback.")
        player.simulateTimeControl(nil)

        stages.removeAll()
        model.attachSubtitle(captions)
        try await wait(diagnostic: model.errorMessage ?? "") { ready() }
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertTrue(stages.contains(.originalStream))
        XCTAssertTrue(stages.contains(.subtitles))
        XCTAssertEqual(model.qualityExplanation, "Prepared for AirPlay without video conversion.")

        defaults.set(false, forKey: "directPlayback")
        defaults.set(false, forKey: "hardwareEncoding")
        let id = try XCTUnwrap(model.current?.id)
        model.select(id, autoPlay: false)
        XCTAssertEqual(model.preparationStage, .readingFile)
        XCTAssertNil(model.qualityTitle, "Do not display the previous stream's quality during inspection")
        try await wait(diagnostic: model.errorMessage ?? "") { ready() }
        XCTAssertFalse(model.isVideoCopied)
        XCTAssertTrue(model.usesSoftwareEncoder)
        XCTAssertFalse(model.usedSoftwareFallback)
        XCTAssertEqual(model.qualityTitle, "Compatibility conversion · up to 1080p SDR")
        XCTAssertTrue(model.qualityExplanation?.contains("Preserve video quality is off.") == true)

        let wrapped = folder.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: wrapped, withIntermediateDirectories: true)
        let wrapper = wrapped.appendingPathComponent("ffmpeg")
        let path = ffmpeg.path.replacingOccurrences(of: "'", with: "'\\''")
        try "#!/bin/sh\nfor argument; do\nif [ \"$argument\" = h264_videotoolbox ]; then exit 9; fi\ndone\nexec '\(path)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try FileManager.default.createSymbolicLink(at: wrapped.appendingPathComponent("ffprobe"), withDestinationURL: ffprobe)
        defaults.set(wrapped.path, forKey: "toolsDirectory")
        defaults.set(true, forKey: "hardwareEncoding")
        stages.removeAll()
        model.select(id, autoPlay: false)
        try await wait(diagnostic: model.errorMessage ?? "") { ready() }
        XCTAssertTrue(model.usesSoftwareEncoder)
        XCTAssertTrue(model.usedSoftwareFallback)
        XCTAssertEqual(stages.filter { [.systemEncoding, .softwareFallback, .softwareEncoding].contains($0) }, [.systemEncoding, .softwareFallback, .softwareEncoding])
        XCTAssertTrue(model.qualityExplanation?.hasPrefix("System conversion failed; using the software encoder.") == true)
        XCTAssertNil(model.errorMessage, "A successful retry must not leave an error alert")

        let unsupported = folder.appendingPathComponent("Unsupported.mkv")
        let av1Generator = Process()
        av1Generator.executableURL = try XCTUnwrap(FFmpegTools().ffmpegURL)
        av1Generator.arguments = ["-v", "error", "-nostdin", "-y", "-i", video.path, "-t", "2", "-an", "-c:v", "libaom-av1", "-cpu-used", "8", "-threads", "2", "-crf", "40", unsupported.path]
        av1Generator.standardInput = FileHandle.nullDevice
        av1Generator.standardOutput = FileHandle.nullDevice
        av1Generator.standardError = FileHandle.nullDevice
        try av1Generator.run(); av1Generator.waitUntilExit()
        XCTAssertEqual(av1Generator.terminationStatus, 0)
        defaults.set(true, forKey: "directPlayback")
        defaults.set(false, forKey: "hardwareEncoding")
        model.add([unsupported])
        try await wait { model.playlist.items.count == 2 }
        model.select(try XCTUnwrap(model.playlist.items.last?.id), autoPlay: false)
        try await wait(diagnostic: model.errorMessage ?? "") { ready() }
        XCTAssertEqual(model.info?.videoCodec, "av1")
        XCTAssertEqual(model.qualityTitle, "Compatibility conversion · up to 1080p SDR")
        XCTAssertTrue(model.qualityExplanation?.contains("This video format requires compatibility conversion.") == true)
        XCTAssertFalse(model.usedSoftwareFallback, "A different video must not retain the previous retry reason")

        model.select(id, autoPlay: false)
        model.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(model.isPreparing)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.isBuffering)
        XCTAssertFalse(model.usedSoftwareFallback)
        XCTAssertFalse(model.usesSoftwareEncoder)
        XCTAssertNil(model.qualityTitle)
        XCTAssertNil(model.qualityExplanation)
        XCTAssertEqual(model.playbackStatus, "Ready to play")
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    @MainActor
    private func wait(diagnostic: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), diagnostic(), file: file, line: line)
        if !condition() { throw CocoaError(.fileReadUnknown) }
    }
}
