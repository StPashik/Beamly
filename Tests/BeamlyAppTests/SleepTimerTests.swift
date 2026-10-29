import AVKit
import BeamlyCore
import XCTest
@testable import Beamly

final class SleepTimerTests: XCTestCase {
    @MainActor
    func testValidationReplacementCancellationAndLifecycle() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-timer-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "app.beamly.timer-lifecycle.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var playlist = Playlist()
        playlist.append([folder.appendingPathComponent("First.mp4"), folder.appendingPathComponent("Second.mp4")])
        playlist.items[0].duration = 60
        playlist.items[0].position = 17
        var models: [AppModel] = []
        defer {
            models.forEach { $0.shutdown() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        func makeModel(_ name: String) throws -> AppModel {
            let state = folder.appendingPathComponent(name + ".json")
            try JSONEncoder().encode(playlist).write(to: state)
            let model = AppModel(stateURL: state, defaults: defaults)
            models.append(model)
            return model
        }
        let model = try makeModel("replacement")
        for value in [0, -1, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
            model.setSleepTimer(value)
            XCTAssertNil(model.sleepTimerRemaining)
        }
        model.setSleepTimer(60)
        model.setSleepTimer(.nan)
        XCTAssertEqual(model.sleepTimerRemaining, 60, "An invalid duration must not cancel an existing timer")
        model.setSleepTimer(1)
        try await Task.sleep(for: .milliseconds(300))
        model.setSleepTimer(2)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertNotNil(model.sleepTimerRemaining, "The replaced deadline must not expire the new timer")
        model.setSleepTimer(nil)
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertNil(model.sleepTimerRemaining)
        XCTAssertNil(model.sleepTimerDescription)
        XCTAssertEqual(model.position, 17)
        model.setSleepTimer(60)
        model.stop()
        XCTAssertNil(model.sleepTimerRemaining)
        XCTAssertEqual(model.position, 0)
        model.setSleepTimer(60)
        model.clear()
        XCTAssertNil(model.sleepTimerRemaining)
        model.setSleepTimer(60)
        XCTAssertNil(model.sleepTimerRemaining, "An empty queue must not arm a timer")

        let removal = try makeModel("removal")
        removal.setSleepTimer(60)
        removal.remove(playlist.items[0].id)
        XCTAssertNotNil(removal.sleepTimerRemaining)
        removal.remove(playlist.items[1].id)
        XCTAssertNil(removal.sleepTimerRemaining)
        let closing = try makeModel("shutdown")
        closing.setSleepTimer(60)
        closing.shutdown()
        XCTAssertNil(closing.sleepTimerRemaining)
    }

    @MainActor
    func testExpiryStopsHLSAndPendingPreparationWithoutLosingPositionOrAdvancingQueue() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL else { throw XCTSkip("FFmpeg is required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-timer-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "app.beamly.timer-playback.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "autoPlay")
        defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
        let mkv = folder.appendingPathComponent("A.mkv")
        let mp4 = folder.appendingPathComponent("B.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=24:d=12",
                             "-f", "lavfi", "-i", "sine=frequency=440:duration=12", "-c:v", "libx264", "-g", "24", "-c:a", "aac", mkv.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let remux = Process()
        remux.executableURL = ffmpeg
        remux.arguments = ["-v", "error", "-nostdin", "-y", "-i", mkv.path, "-c", "copy", mp4.path]
        remux.standardOutput = FileHandle.nullDevice; remux.standardError = FileHandle.nullDevice
        try remux.run(); remux.waitUntilExit()
        XCTAssertEqual(remux.terminationStatus, 0)
        let original = try Data(contentsOf: mkv)
        let player = AirPlayTestPlayer()
        let state = folder.appendingPathComponent("queue.json")
        let model = AppModel(stateURL: state, defaults: defaults, player: player)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        player.isMuted = true
        model.add([mkv, mp4])
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        let first = try XCTUnwrap(model.current?.id)
        let second = try XCTUnwrap(model.playlist.items.last?.id)
        model.setSleepTimer(60)
        model.seek(3)
        try await wait { !model.isPreparing && abs(model.position - 3) < 0.2 }
        model.setAudio(try XCTUnwrap(model.audioOptions.first?.id))
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertNotNil(model.sleepTimerRemaining)
        model.select(second, autoPlay: false)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertNotNil(model.sleepTimerRemaining, "A timer spans the queue rather than restarting for each file")
        model.select(first, autoPlay: false)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(model.isUsingHLS)
        model.seek(3)
        player.setExternalPlaybackActive(true)
        try await wait { model.isExternal }
        model.togglePlay()
        try await wait { model.isPlaying && model.position > 3.1 }
        model.togglePlay()
        XCTAssertNotNil(model.sleepTimerRemaining, "Pausing must not cancel or restart the timer")
        model.togglePlay()
        let oldItem = try XCTUnwrap(player.currentItem)
        model.setSleepTimer(0.15)
        try await wait { model.sleepTimerRemaining == nil && player.currentItem == nil }
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertGreaterThan(model.position, 3)
        XCTAssertEqual(model.current?.id, first)
        let saved = try JSONDecoder().decode(Playlist.self, from: Data(contentsOf: state))
        XCTAssertEqual(try XCTUnwrap(saved.current?.position), model.position, accuracy: 0.01)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.current?.id, first, "A late end notification must not advance the queue")
        XCTAssertNil(player.currentItem)
        let restored = AppModel(stateURL: state, defaults: defaults)
        XCTAssertEqual(restored.position, model.position, accuracy: 0.01)
        XCTAssertNil(restored.sleepTimerRemaining, "Timers must not be restored after relaunch")
        restored.shutdown()

        let calls = player.playCalls
        model.setSleepTimer(0.001)
        model.select(first, autoPlay: true)
        XCTAssertTrue(model.isPreparing)
        try await wait { model.sleepTimerRemaining == nil && !model.isPreparing }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.playCalls, calls, "Expired preparation must not start playback later")
        XCTAssertEqual(try Data(contentsOf: mkv), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path))
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition())
    }
}
