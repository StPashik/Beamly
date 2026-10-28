import AVKit
import XCTest
import BeamlyCore
import SwiftUI
@testable import Beamly

final class PlaybackTests: XCTestCase {
    @MainActor
    func test4KHEVCResumeSeekAudioAndTextSubtitlesKeepOriginalVideo() async throws {
        try await verify4KPlayback(hdr: false)
        if AVPlayer.eligibleForHDRPlayback { try await verify4KPlayback(hdr: true) }
    }

    @MainActor
    private func verify4KPlayback(hdr: Bool) async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL else { throw XCTSkip("FFmpeg is required") }
        let colors = hdr ? "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" : "colorprim=bt709:transfer=bt709:colormatrix=bt709"
        print("Native 4K HEVC fixture: HDR = \(hdr), HDR eligible = \(AVPlayer.eligibleForHDRPlayback)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-4k-player-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("4K HDR.mkv")
        let caption = folder.appendingPathComponent("captions.srt")
        try "1\n00:00:00,500 --> 00:00:07,000\nBeamly 4K subtitle\n".write(to: caption, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = try XCTUnwrap(FFmpegTools().ffmpegURL)
        process.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=blue:size=3840x2160:rate=24:duration=8,drawbox=x=0:y=0:w=iw:h=ih:color=red:t=fill:enable='lt(t,2)'",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=8", "-f", "lavfi", "-i", "sine=frequency=880:duration=8", "-i", caption.path,
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le",
            "-x265-params", "pools=2:frame-threads=2:keyint=48:min-keyint=48:scenecut=0:open-gop=0:log-level=error:\(colors)",
            "-c:a:0", "aac", "-ac:a:0", "2", "-c:a:1", "ac3", "-ac:a:1", "6", "-c:s", "srt", input.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let suite = "app.beamly.4k-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
        defaults.set(false, forKey: "autoPlay")
        var playlist = Playlist()
        playlist.append([input])
        playlist.items[0].position = 3.5
        let state = folder.appendingPathComponent("playlist.json")
        try JSONEncoder().encode(playlist).write(to: state)
        let player = AirPlayTestPlayer()
        let model = AppModel(stateURL: state, defaults: defaults, player: player)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        model.select(playlist.items[0].id, autoPlay: false)
        try await wait(diagnostic: "\(model.errorMessage ?? "no player error"), details=\(String(describing: (player.lastConfiguredItem?.error as NSError?)?.userInfo))") { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertTrue(model.isUsingHLS)
        XCTAssertEqual(model.position, 3.5, accuracy: 0.15)
        XCTAssertEqual(model.info?.width, 3840)
        XCTAssertEqual(model.info?.isHDR, hdr)
        let item = try XCTUnwrap(player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        item.add(output)
        model.volume = 0
        player.setExternalPlaybackActive(true)
        try await wait { model.isExternal }
        model.togglePlay()
        var frame: CVPixelBuffer?
        try await wait(diagnostic: "position=\(model.position), rate=\(player.rate), status=\(item.status.rawValue), error=\(String(describing: item.error)), log=\(String(describing: item.errorLog()?.events.last?.errorComment))") {
            frame = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
            return frame != nil && model.position > 3.7
        }
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(frame)), 3840)
        XCTAssertEqual(CVPixelBufferGetHeight(try XCTUnwrap(frame)), 2160)
        let buffer = try XCTUnwrap(frame)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt16.self)
        // The saved position is blue; a timestamp-only fix showing the first GOP would still be red.
        XCTAssertGreaterThan(Int(chroma[0] >> 6), Int(chroma[1] >> 6) + 80)
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        model.togglePlay()
        try await wait { !model.isPlaying }
        model.seek(6.4)
        try await wait { !model.isPreparing && abs(model.position - 6.4) < 0.2 }
        XCTAssertTrue(model.isVideoCopied)
        model.seek(1.3)
        try await wait { !model.isPreparing && abs(model.position - 1.3) < 0.2 }
        XCTAssertTrue(model.isVideoCopied)
        model.setAudio(2)
        try await wait(diagnostic: model.errorMessage ?? "no player error") { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.audioID, 2)
        XCTAssertEqual(model.position, 1.3, accuracy: 0.2)
        XCTAssertTrue(model.isVideoCopied)
        model.setSubtitle(3)
        try await wait(diagnostic: model.errorMessage ?? "no player error") { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        let subtitles = try await player.currentItem?.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(subtitles)
        XCTAssertNotNil(player.currentItem?.currentMediaSelection.selectedMediaOption(in: group))
        XCTAssertTrue(model.isVideoCopied)
        model.add([caption])
        try await wait { model.externalSubtitle == caption && !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertEqual(model.position, 1.3, accuracy: 0.2)
        model.setSubtitle(nil)
        try await wait(diagnostic: model.errorMessage ?? "no player error") { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    @MainActor
    func testDirectTracksHLSRoundtripRemovalAndCancellation() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL, tools.ffprobeURL != nil else { throw XCTSkip("FFmpeg не установлен") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "app.beamly.check.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoPlay")
        defaults.set(false, forKey: "hardwareEncoding")
        defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
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
        let player = AirPlayTestPlayer()
        let model = AppModel(stateURL: state, defaults: defaults, player: player)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        model.select(saved.items[0].id, autoPlay: false)
        try await wait { model.player.currentItem?.status == .readyToPlay && !model.isPreparing }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isUsingHLS)
        XCTAssertEqual(model.audioOptions.count, 2)
        model.volume = 0
        // Neither a manual request nor automatic preparation may play locally.
        model.togglePlay()
        XCTAssertEqual(player.playCalls, 0)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isAirPlayPickerRequested)
        model.select(saved.items[0].id)
        try await wait { !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(player.playCalls, 0)
        player.setExternalPlaybackActive(true)
        try await wait { model.isPlaying }
        player.setExternalPlaybackActive(false)
        try await wait { !model.isPlaying && !model.isExternal }
        XCTAssertEqual(player.rate, 0)
        let callsAfterDisconnect = player.playCalls
        model.togglePlay()
        XCTAssertEqual(player.playCalls, callsAfterDisconnect)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isAirPlayPickerRequested)
        player.setExternalPlaybackActive(true)
        try await wait { model.isExternal && model.isPlaying }
        model.togglePlay()
        XCTAssertEqual(player.rate, 0)
        try await wait { !model.isPlaying }
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
        try await wait(diagnostic: model.errorMessage ?? "no player error") { model.isUsingHLS && !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.externalSubtitle, subtitle)
        let embedded = try XCTUnwrap(model.subtitleOptions.first)
        model.setSubtitle(embedded.id)
        try await wait { !model.isUsingHLS && !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        let restoredItem = try XCTUnwrap(model.player.currentItem)
        let loadedCaptions = try await restoredItem.asset.loadMediaSelectionGroup(for: .legible)
        let captions = try XCTUnwrap(loadedCaptions)
        XCTAssertNotNil(restoredItem.currentMediaSelection.selectedMediaOption(in: captions))
        XCTAssertEqual(model.subtitleID, embedded.id)

        let captionPosition = model.position
        model.setSubtitleDelay(1.5)
        try await wait(diagnostic: model.errorMessage ?? "no player error") { model.isUsingHLS && !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertEqual(model.position, captionPosition, accuracy: 0.2)
        XCTAssertEqual(model.subtitleID, embedded.id)
        model.setSubtitleDelay(-0.5)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        model.setSubtitleDelay(.nan)
        XCTAssertEqual(model.subtitleDelay, -0.5)
        let persisted = try JSONDecoder().decode(Playlist.self, from: Data(contentsOf: state))
        XCTAssertEqual(persisted.items[0].subtitleDelay, -0.5)
        XCTAssertNil(persisted.items[1].subtitleDelay)

        let english = folder.appendingPathComponent("First.en.srt")
        let russian = folder.appendingPathComponent("First.ru.srt")
        try FileManager.default.copyItem(at: subtitle, to: english)
        model.select(saved.items[0].id, autoPlay: false)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(model.externalSubtitleOptions.map { $0.resolvingSymlinksInPath().path }, [english.resolvingSymlinksInPath().path])
        XCTAssertEqual(model.externalSubtitle?.resolvingSymlinksInPath().path, english.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.subtitleDelay, -0.5)
        try FileManager.default.copyItem(at: subtitle, to: russian)
        model.select(saved.items[0].id, autoPlay: false)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(Set(model.externalSubtitleOptions.map { $0.resolvingSymlinksInPath().path }), Set([english, russian].map { $0.resolvingSymlinksInPath().path }))
        XCTAssertNil(model.externalSubtitle, "Multiple languages require an explicit choice")
        model.attachSubtitle(russian)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(model.externalSubtitle?.resolvingSymlinksInPath().path, russian.resolvingSymlinksInPath().path)
        model.setSubtitle(nil)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertNil(model.externalSubtitle, "Rebuilding the stream must retain the Off selection")
        let plain = folder.appendingPathComponent("First.srt")
        try FileManager.default.copyItem(at: subtitle, to: plain)
        model.select(saved.items[0].id, autoPlay: false)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(model.externalSubtitle?.resolvingSymlinksInPath().path, plain.resolvingSymlinksInPath().path, "An exact-basename file takes priority")

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
        XCTAssertEqual(model.subtitleDelay, 0)
        XCTAssertTrue(model.externalSubtitleOptions.isEmpty)
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
    func testSavedTrackPreferencesAcrossNativePlaybackHLSQueueAndRelaunch() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL, tools.ffprobeURL != nil else { throw XCTSkip("FFmpeg is required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-track-preferences-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "app.beamly.track-preferences.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoPlay")
        defaults.set(false, forKey: "hardwareEncoding")
        defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
        defaults.set("ru", forKey: "preferredAudioLanguage")
        defaults.set("off", forKey: "preferredSubtitleLanguage")
        let russian = folder.appendingPathComponent("First.ru.srt")
        try "1\n00:00:00,500 --> 00:00:07,000\nTrack preference caption\n".write(to: russian, atomically: true, encoding: .utf8)
        let first = folder.appendingPathComponent("First.mp4")
        let second = folder.appendingPathComponent("Second.mkv")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=blue:size=160x90:rate=24:duration=8",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=8", "-f", "lavfi", "-i", "sine=frequency=880:duration=8", "-i", russian.path,
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-c:v", "libx264", "-c:a", "aac", "-c:s", "mov_text",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=rus", "-metadata:s:s:0", "language=eng",
            "-disposition:a:0", "0", "-disposition:a:1", "default", "-movflags", "+faststart", first.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let remux = Process()
        remux.executableURL = ffmpeg
        remux.arguments = ["-v", "error", "-nostdin", "-y", "-i", first.path, "-map", "0", "-c", "copy", "-c:s", "srt", "-disposition:a:0", "original", second.path]
        remux.standardInput = FileHandle.nullDevice
        remux.standardOutput = FileHandle.nullDevice
        remux.standardError = FileHandle.nullDevice
        try remux.run(); remux.waitUntilExit()
        XCTAssertEqual(remux.terminationStatus, 0)
        var playlist = Playlist()
        playlist.append([first, second])
        let state = folder.appendingPathComponent("playlist.json")
        try JSONEncoder().encode(playlist).write(to: state)
        let player = AirPlayTestPlayer()
        let model = AppModel(stateURL: state, defaults: defaults, player: player)
        defer { model.shutdown() }
        model.select(playlist.items[0].id, autoPlay: false)
        try await wait(diagnostic: model.errorMessage ?? "no player error") { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertFalse(model.isUsingHLS)
        XCTAssertEqual(model.audioID, 2)
        XCTAssertNil(model.subtitleID)
        XCTAssertNil(model.externalSubtitle, "Off must ignore adjacent files")
        let item = try XCTUnwrap(player.currentItem)
        let loadedAudio = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loadedAudio)
        XCTAssertEqual(MediaLanguages.normalized(item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag), "ru")
        let loadedSubtitles = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let captions = try XCTUnwrap(loadedSubtitles)
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: captions))
        model.setAudio(nil)
        XCTAssertEqual(MediaLanguages.normalized(item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag), "ru", "File default is the flagged track, not the first stream")
        model.setAudio(1)
        model.setSubtitle(3)
        model.seek(2)
        model.setSubtitleDelay(0.5)
        try await wait(diagnostic: model.errorMessage ?? "no player error") { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(model.isUsingHLS)
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertEqual(model.audioID, 1)
        XCTAssertEqual(model.subtitleID, 3, "Rebuilds retain manual captions despite global Off")
        model.seek(5)
        try await wait { !model.isPreparing && abs(model.position - 5) < 0.2 }
        defaults.set("original", forKey: "preferredAudioLanguage")
        defaults.set("ru", forKey: "preferredSubtitleLanguage")
        XCTAssertEqual(model.audioID, 1)
        XCTAssertEqual(model.subtitleID, 3)
        model.next()
        try await wait(diagnostic: model.errorMessage ?? "no player error") { model.current?.url == second && !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(model.info?.audioTracks.first?.isOriginal == true)
        XCTAssertEqual(model.info?.defaultAudioTrack?.id, 2)
        XCTAssertEqual(model.audioID, 1)
        XCTAssertNil(model.subtitleID, "Missing preferred subtitles must stay off")
        model.setAudio(nil)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        let hlsAudio = try await player.currentItem?.asset.loadMediaSelectionGroup(for: .audible)
        let hlsGroup = try XCTUnwrap(hlsAudio)
        XCTAssertEqual(MediaLanguages.normalized(player.currentItem?.currentMediaSelection.selectedMediaOption(in: hlsGroup)?.extendedLanguageTag), "ru")
        defaults.set("en", forKey: "preferredAudioLanguage")
        model.select(playlist.items[0].id, autoPlay: false)
        try await wait { !model.isPreparing && player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(model.audioID, 1)
        XCTAssertEqual(model.externalSubtitle?.resolvingSymlinksInPath().path, russian.resolvingSymlinksInPath().path)
        model.shutdown()
        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restored = AppModel(stateURL: state, defaults: restoredDefaults, player: AirPlayTestPlayer())
        defer { restored.shutdown() }
        restored.select(playlist.items[0].id, autoPlay: false)
        try await wait { !restored.isPreparing && restored.player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(restored.audioID, 1)
        XCTAssertEqual(restored.externalSubtitle?.resolvingSymlinksInPath().path, russian.resolvingSymlinksInPath().path)
        XCTAssertNil(restored.errorMessage)
    }

    @MainActor
    private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = findTable(child) { return table } }
        return nil
    }

    @MainActor
    private func wait(diagnostic: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(condition(), "Playback did not reach expected state: \(diagnostic())", file: file, line: line)
        if !condition() { throw CocoaError(.fileReadUnknown) }
    }
}

// Simulates the system's route signal; the AVPlayer decoder and clock remain real.
private final class AirPlayTestPlayer: AVPlayer, @unchecked Sendable {
    private let lock = NSLock()
    private var external = false
    private(set) var playCalls = 0
    private(set) var lastConfiguredItem: AVPlayerItem?

    override func replaceCurrentItem(with item: AVPlayerItem?) {
        if let item { lastConfiguredItem = item }
        super.replaceCurrentItem(with: item)
    }

    override var isExternalPlaybackActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return external
    }

    func setExternalPlaybackActive(_ value: Bool) {
        willChangeValue(forKey: #keyPath(AVPlayer.isExternalPlaybackActive))
        lock.lock()
        external = value
        lock.unlock()
        didChangeValue(forKey: #keyPath(AVPlayer.isExternalPlaybackActive))
    }

    override func play() {
        playCalls += 1
        super.play()
    }
}
