import AppKit
import AVFoundation
import BeamlyCore
import SwiftUI
import XCTest
@testable import Beamly

final class PreviewTests: XCTestCase {
    @MainActor
    func testChaptersAndSeekFramesForMP4AndMKVKeepPlaybackState() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL, tools.ffprobeURL != nil else { throw XCTSkip("FFmpeg is not installed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-preview-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mp4 = folder.appendingPathComponent("Red then blue.mp4")
        let mkv = folder.appendingPathComponent("Red then blue.mkv")
        let chapterMetadata = folder.appendingPathComponent("chapters.txt")
        try ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=Red intro\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=2000\nEND=12000\ntitle=Blue chapter\n".write(to: chapterMetadata, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = ffmpeg
        // The first frame is red; the midpoint at six seconds must be blue.
        process.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=red:s=160x90:r=10:d=2",
                             "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=10:d=10", "-f", "lavfi", "-i", "sine=frequency=440:duration=12",
                             "-f", "ffmetadata", "-i", chapterMetadata.path,
                             "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
                             "-map", "[v]", "-map", "2:a", "-map_chapters", "3", "-c:v", "libx264", "-c:a", "aac", "-g", "10", "-pix_fmt", "yuv420p", mp4.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let remux = Process()
        remux.executableURL = ffmpeg
        remux.arguments = ["-v", "error", "-nostdin", "-y", "-i", mp4.path, "-c", "copy", mkv.path]
        remux.standardInput = FileHandle.nullDevice
        remux.standardOutput = FileHandle.nullDevice
        remux.standardError = FileHandle.nullDevice
        try remux.run()
        remux.waitUntilExit()
        XCTAssertEqual(remux.terminationStatus, 0)

        for invalid in [-1, Double.infinity, Double.nan] {
            do {
                _ = try await tools.thumbnail(url: mp4, at: invalid)
                XCTFail("Invalid thumbnail time was accepted")
            } catch MediaPipelineError.invalidMedia { }
        }

        let png = try await tools.thumbnail(url: mkv, at: 3)
        try assertBlue(try XCTUnwrap(NSImage(data: png)))
        for movie in [mp4, mkv] {
            let metadata = try await tools.probe(url: movie)
            XCTAssertEqual(metadata.chapters?.map(\.title), ["Red intro", "Blue chapter"])
            XCTAssertEqual(metadata.chapters?.map(\.start), [0, 2])
            if movie == mp4 {
                let native = await AppModel.nativeChapters(in: AVURLAsset(url: mp4), duration: 12)
                XCTAssertEqual(native.map(\.title), ["Red intro", "Blue chapter"])
            }
            let name = "app.beamly.preview-tests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
            var saved = Playlist()
            saved.append([movie])
            saved.items[0].duration = 12
            let state = folder.appendingPathComponent("queue-\(movie.pathExtension).json")
            try JSONEncoder().encode(saved).write(to: state)
            let model = AppModel(stateURL: state, defaults: defaults)
            defer { model.shutdown(); defaults.removePersistentDomain(forName: name) }
            let deadline = Date().addingTimeInterval(15)
            while model.previewImage == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            let image = try XCTUnwrap(model.previewImage, movie.pathExtension)
            try assertBlue(image)
            XCTAssertNil(model.player.currentItem)
            XCTAssertEqual(model.player.rate, 0)
            XCTAssertEqual(model.position, 0)

            model.requestSeekPreview(0.8)
            try await wait { !model.isLoadingSeekPreview }
            let red = try XCTUnwrap(model.seekPreviewImage)
            try assertColor(red, blue: false)
            XCTAssertEqual(model.seekPreviewTime, 0)
            model.requestSeekPreview(nil)
            XCTAssertNil(model.seekPreviewImage)
            model.requestSeekPreview(0.9)
            XCTAssertTrue(model.seekPreviewImage === red, "Repeated source seconds reuse the frame cache")
            model.requestSeekPreview(5.2)
            try await wait { !model.isLoadingSeekPreview }
            try assertBlue(try XCTUnwrap(model.seekPreviewImage))
            XCTAssertNil(model.player.currentItem)
            XCTAssertEqual(model.player.rate, 0)
            XCTAssertEqual(model.position, 0, "Hovering must not change the saved resume position")
            XCTAssertTrue(model.previewImage === image)
            for invalid in [-1, Double.nan, Double.infinity] {
                model.requestSeekPreview(invalid)
                XCTAssertNil(model.seekPreviewTime)
                XCTAssertNil(model.seekPreviewImage)
            }
            for time in [1.0, 3.0, 4.0] { model.requestSeekPreview(time) }
            model.requestSeekPreview(nil)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertNil(model.seekPreviewImage, "Cancelled thumbnail requests must not return stale frames")

            model.seek(8.5)
            XCTAssertTrue(model.previewImage === image)
            model.select(try XCTUnwrap(model.current?.id), autoPlay: false)
            try await wait { !model.isPreparing }
            XCTAssertNil(model.errorMessage, movie.lastPathComponent)
            XCTAssertEqual(model.position, 8.5, accuracy: 0.15)
            XCTAssertEqual(model.isUsingHLS, movie == mkv)
            XCTAssertEqual(model.chapters.count, 2)
            XCTAssertEqual(model.chapter(at: 1.99)?.title, "Red intro")
            XCTAssertEqual(model.chapter(at: 2)?.title, "Blue chapter")
            XCTAssertNil(model.chapter(at: 12))
            XCTAssertNil(model.chapter(at: .nan))
            model.seekChapter(try XCTUnwrap(model.chapters.first?.id))
            try await wait { !model.isPreparing && model.player.currentItem?.status == .readyToPlay && model.position < 0.25 }
            XCTAssertEqual(model.player.rate, 0, "Chapter navigation must preserve paused playback")
            model.seekChapter(try XCTUnwrap(model.chapters.last?.id))
            try await wait { !model.isPreparing && model.position >= 1.9 && model.position < 2.25 }
            XCTAssertEqual(model.chapter(at: model.position)?.title, "Blue chapter")
            XCTAssertEqual(model.player.rate, 0)
            if movie == mp4 {
                let fallback = folder.appendingPathComponent("fallback-tools")
                try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
                let probe = fallback.appendingPathComponent("ffprobe")
                try "#!/bin/sh\nexit 9\n".write(to: probe, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
                try FileManager.default.createSymbolicLink(at: fallback.appendingPathComponent("ffmpeg"), withDestinationURL: ffmpeg)
                defaults.set(fallback.path, forKey: "toolsDirectory")
                model.select(try XCTUnwrap(model.current?.id), autoPlay: false)
                try await wait { !model.isPreparing }
                XCTAssertNil(model.errorMessage)
                XCTAssertEqual(model.chapters.map(\.title), ["Red intro", "Blue chapter"], "Native chapters survive a probe failure")
            }
            model.requestSeekPreview(1)
            model.clear()
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertNil(model.previewImage)
            XCTAssertNil(model.seekPreviewImage)
            XCTAssertNil(model.seekPreviewTime)
            XCTAssertTrue(model.chapters.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
        }

        let silent = folder.appendingPathComponent("Video only.mkv")
        let removeAudio = Process()
        removeAudio.executableURL = ffmpeg
        removeAudio.arguments = ["-v", "error", "-nostdin", "-y", "-i", mkv.path, "-map", "0:v", "-c:v", "copy", "-an", silent.path]
        removeAudio.standardOutput = FileHandle.nullDevice; removeAudio.standardError = FileHandle.nullDevice
        try removeAudio.run(); removeAudio.waitUntilExit()
        XCTAssertEqual(removeAudio.terminationStatus, 0)
        let silentInfo = try await tools.probe(url: silent)
        let job = HLSJob(tools: tools)
        defer { job.stop() }
        let master = try await job.start(input: silent, info: silentInfo, audioTrack: nil, subtitle: .none, startTime: 0, hardwareEncoding: false)
        let directory = master.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("init_0.mp4").path))
        let media = try String(contentsOf: directory.appendingPathComponent("stream_0.m3u8"), encoding: .utf8)
        XCTAssertTrue(media.contains("URI=\"init_0.mp4\""))
        XCTAssertFalse(media.contains("%v"), "Single-variant initialization paths must be literal and usable by AVFoundation")
    }

    func testTimelinePreviewClampsEndpointsAndKeepsTheBubbleInsideTheTrack() {
        XCTAssertEqual(SeekTimeline.time(at: -10, width: 200, duration: 60), 0)
        XCTAssertEqual(SeekTimeline.time(at: 100, width: 200, duration: 60), 30)
        XCTAssertEqual(SeekTimeline.time(at: 210, width: 200, duration: 60), 60)
        XCTAssertEqual(SeekTimeline.time(at: 8, width: 200, duration: 7200, inset: 8), 0)
        XCTAssertEqual(SeekTimeline.time(at: 192, width: 200, duration: 7200, inset: 8), 7200)
        XCTAssertEqual(SeekTimeline.time(at: 100, width: 200, duration: 7200, inset: 8), 3600)
        XCTAssertNil(SeekTimeline.time(at: 8, width: 16, duration: 60, inset: 8))
        XCTAssertNil(SeekTimeline.time(at: .nan, width: 200, duration: 60))
        XCTAssertNil(SeekTimeline.time(at: 10, width: 0, duration: 60))
        XCTAssertNil(SeekTimeline.time(at: 10, width: 200, duration: .infinity))
        XCTAssertEqual(SeekTimeline.previewOrigin(at: 0, width: 300, duration: 60), 0)
        XCTAssertEqual(SeekTimeline.previewOrigin(at: 30, width: 300, duration: 60), 70)
        XCTAssertEqual(SeekTimeline.previewOrigin(at: 60, width: 300, duration: 60), 140)
        XCTAssertEqual(SeekTimeline.previewOrigin(at: 60, width: 100, duration: 60), 0)
    }

    @MainActor
    func testNativeTimelineKeyboardSeeksWithoutStartingPlayback() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-keyboard-seek-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "app.beamly.keyboard-seek.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        var playlist = Playlist()
        playlist.append([folder.appendingPathComponent("Movie.mp4")])
        playlist.items[0].duration = 60
        let state = folder.appendingPathComponent("queue.json")
        try JSONEncoder().encode(playlist).write(to: state)
        let model = AppModel(stateURL: state, defaults: defaults)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) }
        var scrubbing = false
        var position = 0.0
        let host = NSHostingView(rootView: SeekTimeline(model: model, scrubbing: Binding(get: { scrubbing }, set: { scrubbing = $0 }),
                                                       position: Binding(get: { position }, set: { position = $0 })).frame(width: 300, height: 24))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 24), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 50_000_000)
        func findSlider(_ view: NSView) -> NSSlider? {
            if let slider = view as? NSSlider { return slider }
            return view.subviews.lazy.compactMap { findSlider($0) }.first
        }
        let slider = try XCTUnwrap(findSlider(host))
        XCTAssertTrue(window.makeFirstResponder(slider))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        slider.keyDown(with: event)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(model.position, 0)
        let fraction = (slider.doubleValue - slider.minValue) / (slider.maxValue - slider.minValue)
        XCTAssertEqual(model.position, fraction * model.duration, accuracy: 0.01)
        XCTAssertFalse(scrubbing)
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.player.rate, 0)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertTrue(condition())
    }

    private func assertBlue(_ image: NSImage, file: StaticString = #filePath, line: UInt = #line) throws {
        try assertColor(image, blue: true, file: file, line: line)
    }

    private func assertColor(_ image: NSImage, blue: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), file: file, line: line)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB), file: file, line: line)
        XCTAssertGreaterThan(blue ? color.blueComponent : color.redComponent, 0.8, file: file, line: line)
        XCTAssertLessThan(blue ? color.redComponent : color.blueComponent, 0.2, file: file, line: line)
        XCTAssertLessThanOrEqual(bitmap.pixelsWide, 288)
        XCTAssertLessThanOrEqual(bitmap.pixelsHigh, 162)
    }
}
