import AppKit
import AVKit
import BeamlyCore
import SwiftUI
import XCTest
@testable import Beamly

final class PlaybackExtrasTests: XCTestCase {
    @MainActor
    func testHistoryMigrationAudioCorrectionsRemovalAndResume() async throws {
        let tools = mediaTestTools()
        let ffmpeg = try XCTUnwrap(tools.ffmpegURL)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-history-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("First.mp4")
        let second = folder.appendingPathComponent("Second.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=blue:size=160x90:rate=10:duration=20",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=20", "-f", "lavfi", "-i", "sine=frequency=880:duration=20",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264", "-g", "10", "-bf", "0", "-c:a", "aac", first.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.copyItem(at: first, to: second)
        let original = try Data(contentsOf: first)
        let suite = "app.beamly.history-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
        defaults.set(false, forKey: "autoPlay")
        var playlist = Playlist()
        playlist.append([first, second])
        playlist.items[0].position = 7
        playlist.items[0].duration = 20
        let state = folder.appendingPathComponent("playlist.json")
        try JSONEncoder().encode(playlist).write(to: state)
        let player = AirPlayTestPlayer()
        let model = AppModel(stateURL: state, defaults: defaults, player: player)
        var restored: AppModel?
        defer {
            model.shutdown(); restored?.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        XCTAssertEqual(model.watchHistory.first?.video.position, 7, "Old queue positions migrate into history")
        model.select(playlist.items[0].id, autoPlay: false)
        try await ready(model)
        XCTAssertFalse(model.isUsingHLS)
        model.setAudio(2)
        model.setAudioDelay(0.4)
        try await ready(model)
        XCTAssertTrue(model.isUsingHLS)
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertEqual(model.audioID, 2)
        XCTAssertEqual(model.position, 7, accuracy: 0.15)
        let correctedItem = player.currentItem
        model.setAudioDelay(0.4000000000000001)
        XCTAssertTrue(player.currentItem === correctedItem, "Rounding to the same correction must not rebuild playback")
        model.seek(1.5)
        try await ready(model)
        XCTAssertEqual(model.audioDelay, 0.4)
        model.setAudioDelay(-0.2)
        try await ready(model)
        for value in [Double.nan, .infinity, 11, -11] { model.setAudioDelay(value) }
        XCTAssertEqual(model.audioDelay, -0.2)
        model.setAudioDelay(0.1 + 0.2 - 0.3)
        try await ready(model)
        XCTAssertEqual(model.audioDelay, 0)
        XCTAssertNil(model.current?.audioDelay, "Returning the native stepper to zero must remove the correction exactly")
        XCTAssertFalse(model.isUsingHLS, "Zero correction restores eligible direct playback")
        model.setAudioDelay(0.5)
        try await ready(model)
        model.seek(8)
        try await ready(model)
        model.setSubtitleDelay(1)
        model.remove(playlist.items[0].id)
        XCTAssertEqual(model.watchHistory.first?.id, first)
        XCTAssertEqual(model.watchHistory.first?.video.position ?? -1, 8, accuracy: 0.15)
        XCTAssertEqual(model.watchHistory.first?.video.audioDelay, 0.5)
        XCTAssertEqual(model.audioDelay, 0, "Other movies have independent timing")
        try await ready(model)
        model.setAudioDelay(-0.3)
        model.remove(playlist.items[1].id)
        XCTAssertEqual(model.watchHistory.first?.video.audioDelay, -0.3, "Corrections survive removal during preparation, even before playback starts")
        model.clear()
        XCTAssertTrue(model.playlist.items.isEmpty)
        model.shutdown()

        let reloadedPlayer = AirPlayTestPlayer()
        let reloaded = AppModel(stateURL: state, defaults: defaults, player: reloadedPlayer)
        restored = reloaded
        reloaded.add([first])
        try await ready(reloaded)
        XCTAssertEqual(reloaded.playlist.items.count, 1)
        XCTAssertEqual(reloaded.audioDelay, 0.5)
        XCTAssertEqual(reloaded.subtitleDelay, 1)
        XCTAssertEqual(reloaded.position, 8, accuracy: 0.15)
        XCTAssertNotEqual(reloaded.current?.id, playlist.items[0].id, "Re-adding a movie creates a new queue entry with its saved resume point")
        XCTAssertEqual(reloadedPlayer.playCalls, 0, "History resume must still require an AirPlay route")
        reloaded.seek(10)
        try await ready(reloaded)
        reloaded.resumeHistory(first)
        try await ready(reloaded)
        XCTAssertEqual(reloaded.position, 10, accuracy: 0.15, "Resuming the active movie uses its latest position")
        XCTAssertEqual(reloaded.playlist.items.count, 1)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: reloaded.player.currentItem)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try XCTUnwrap(reloaded.watchHistory.first).isFinished)
        XCTAssertEqual(reloaded.watchHistory.first?.video.position ?? -1, reloaded.duration, accuracy: 0.15)
        reloaded.resumeHistory(first)
        try await ready(reloaded)
        XCTAssertEqual(reloaded.position, 0, accuracy: 0.15, "Completed movies restart from the beginning")
        reloaded.removeHistory(first)
        XCTAssertFalse(reloaded.watchHistory.contains { $0.id == first })
        XCTAssertTrue(reloaded.watchHistory.contains { $0.id == second })
        XCTAssertEqual(reloaded.current?.url, first)
        reloaded.clearHistory()
        XCTAssertTrue(reloaded.watchHistory.isEmpty)
        reloaded.shutdown()
        let forgotten = try JSONDecoder().decode(Playlist.self, from: Data(contentsOf: state))
        XCTAssertEqual(forgotten.history, [], "Quitting an unchanged paused session must not recreate cleared history")
        XCTAssertNotNil(forgotten.current)
        try FileManager.default.removeItem(at: first)
        reloaded.resumeHistory(first)
        XCTAssertNotNil(reloaded.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "History operations must not delete source movies")
        XCTAssertEqual(try Data(contentsOf: second), original)
    }

    @MainActor
    func testMiniRemoteUsesSharedModelAndClosingWindowKeepsPlaybackAvailable() async throws {
        let app = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-mini-remote-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = folder.appendingPathComponent("playlist.json")
        var playlist = Playlist()
        playlist.append([folder.appendingPathComponent("Generated.mp4")])
        playlist.items[0].position = 20; playlist.items[0].duration = 60
        try JSONEncoder().encode(playlist).write(to: state)
        let suite = "app.beamly.mini-remote-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(stateURL: state, defaults: defaults)
        let delegate = AppDelegate()
        delegate.attach(model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 310, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close(); model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        window.contentView = NSHostingView(rootView: MenuBarRemote(model: model))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        func findSlider(_ view: NSView) -> NSSlider? {
            if let slider = view as? NSSlider { return slider }
            return view.subviews.lazy.compactMap(findSlider).first
        }
        XCTAssertNil(window.contentView.flatMap(findSlider), "Volume belongs to the receiver, not the mini remote")
        func containsStop(_ view: NSView) -> Bool {
            if let button = view as? NSButton, button.title == "Stop" || button.accessibilityLabel() == "Stop" { return true }
            return view.subviews.contains(where: containsStop)
        }
        XCTAssertFalse(window.contentView.map(containsStop) ?? false)
        model.setSleepTimer(60)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(app))
        window.performClose(nil)
        XCTAssertNotNil(model.current)
        XCTAssertNotNil(model.sleepTimerRemaining, "Closing a window must not stop the playback session")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let saved = try JSONDecoder().decode(Playlist.self, from: Data(contentsOf: state))
        XCTAssertEqual(saved.current?.position, 20)
        XCTAssertNil(model.sleepTimerRemaining)
    }

    @MainActor private func ready(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(25)
        while (model.isPreparing || model.player.currentItem?.status != .readyToPlay), model.errorMessage == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(model.player.currentItem?.status, .readyToPlay)
        if model.isPreparing || model.player.currentItem?.status != .readyToPlay { throw CocoaError(.fileReadUnknown) }
    }
}
