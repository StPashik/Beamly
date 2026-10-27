import AVKit
import XCTest
import BeamlyCore
import SwiftUI
@testable import Beamly

final class PlaybackTests: XCTestCase {
    @MainActor
    func testDirectTracksHLSRoundtripRemovalAndCancellation() async throws {
        let tools = FFmpegTools()
        guard let ffmpeg = tools.ffmpegURL, tools.ffprobeURL != nil else { throw XCTSkip("FFmpeg не установлен") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "app.beamly.check.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoPlay")
        defaults.set(false, forKey: "hardwareEncoding")
        let subtitle = folder.appendingPathComponent("captions.srt")
        try "1\n00:00:00,500 --> 00:00:10,000\nBeamly integration\n".write(to: subtitle, atomically: true, encoding: .utf8)
        let first = folder.appendingPathComponent("First.mp4")
        let second = folder.appendingPathComponent("Second.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=16", "-f", "lavfi", "-i", "sine=frequency=440:duration=16", "-f", "lavfi", "-i", "sine=frequency=880:duration=16", "-i", subtitle.path, "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-c:v", "libx264", "-c:a", "aac", "-c:s", "mov_text", "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=rus", "-metadata:s:s:0", "language=eng", "-movflags", "+faststart", first.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.copyItem(at: first, to: second)
        var saved = Playlist()
        saved.append([first, second])
        saved.items[0].position = 7
        saved.items[1].position = 2
        let state = folder.appendingPathComponent("playlist.json")
        try JSONEncoder().encode(saved).write(to: state)
        let model = AppModel(stateURL: state, defaults: defaults)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        model.select(saved.items[0].id, autoPlay: false)
        try await wait { model.player.currentItem?.status == .readyToPlay && !model.isPreparing }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isTranscoding)
        XCTAssertEqual(model.audioOptions.count, 2)
        model.volume = 0
        let startingPosition = model.position
        model.togglePlay()
        try await wait { model.isPlaying && model.position > startingPosition + 0.2 }
        model.togglePlay()
        XCTAssertEqual(model.player.rate, 0)
        let secondAudio = try XCTUnwrap(model.audioOptions.last)
        model.setAudio(secondAudio.id)
        let nativeItem = try XCTUnwrap(model.player.currentItem)
        let loadedAudio = try await nativeItem.asset.loadMediaSelectionGroup(for: .audible)
        let audioGroup = try XCTUnwrap(loadedAudio)
        XCTAssertEqual(nativeItem.currentMediaSelection.selectedMediaOption(in: audioGroup)?.displayName, secondAudio.title)
        model.setAudio(nil)
        XCTAssertNotNil(nativeItem.currentMediaSelection.selectedMediaOption(in: audioGroup))

        model.add([subtitle])
        try await wait { model.isTranscoding && !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.externalSubtitle, subtitle)
        let embedded = try XCTUnwrap(model.subtitleOptions.first)
        model.setSubtitle(embedded.id)
        try await wait { !model.isTranscoding && !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        let restoredItem = try XCTUnwrap(model.player.currentItem)
        let loadedCaptions = try await restoredItem.asset.loadMediaSelectionGroup(for: .legible)
        let captions = try XCTUnwrap(loadedCaptions)
        XCTAssertNotNil(restoredItem.currentMediaSelection.selectedMediaOption(in: captions))
        XCTAssertEqual(model.subtitleID, embedded.id)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 674, height: 390), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model).frame(width: 674, height: 390))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let table = try XCTUnwrap(window.contentView.flatMap(findTable))
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertTrue(window.makeFirstResponder(table))
        // SwiftUI registers the focused delete handler on the next run-loop turn.
        try await Task.sleep(nanoseconds: 100_000_000)
        let delete = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        window.sendEvent(delete)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.playlist.items.count, 1)
        try await wait { !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(model.current?.url, second)
        XCTAssertEqual(model.current?.position ?? -1, 2, accuracy: 0.6)
        XCTAssertEqual(model.player.currentTime().seconds, 2, accuracy: 0.6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        model.select(saved.items[1].id, autoPlay: false)
        model.clear()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(model.player.currentItem)
        XCTAssertTrue(model.playlist.items.isEmpty)
        XCTAssertFalse(model.isPreparing)
    }

    @MainActor
    private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = findTable(child) { return table } }
        return nil
    }

    @MainActor
    private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(condition(), "Playback did not reach expected state", file: file, line: line)
        if !condition() { throw CocoaError(.fileReadUnknown) }
    }
}
