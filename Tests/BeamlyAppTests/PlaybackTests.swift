import AVKit
import XCTest
import BeamlyCore
import Combine
import MediaPlayer
import SwiftUI
@testable import Beamly

final class PlaybackTests: XCTestCase {
    @MainActor
    func testIndexedHLSResumesAndSeeksBeforeTheSequentialRemuxCompletes() async throws {
        try await checkIndexedHLS(hevc: false)
    }

    @MainActor
    func testIndexedHEVCResumesAndSeeksBeforeTheSequentialRemuxCompletes() async throws {
        try await checkIndexedHLS(hevc: true)
        if AVPlayer.eligibleForHDRPlayback { try await checkIndexedHLS(hevc: true, hdr: true) }
    }

    @MainActor
    private func checkIndexedHLS(hevc: Bool, hdr: Bool = false) async throws {
        let tools = mediaTestTools()
        let ffmpeg = try XCTUnwrap(tools.ffmpegURL)
        let ffprobe = try XCTUnwrap(tools.ffprobeURL)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-early-hls-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("Movie.mkv")
        let captions = folder.appendingPathComponent("captions.srt")
        let chapters = folder.appendingPathComponent("chapters.ffmetadata")
        try "1\n00:00:01,000 --> 00:01:03,000\nEarly HLS caption\n".write(to: captions, atomically: true, encoding: .utf8)
        try ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=60000\ntitle=Movie\n".write(to: chapters, atomically: true, encoding: .utf8)
        let generator = Process()
        generator.executableURL = hevc ? try XCTUnwrap(FFmpegTools().ffmpegURL) : ffmpeg
        let colors = hdr
            ? "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"
            : "colorprim=bt709:transfer=bt709:colormatrix=bt709"
        let video = hevc ? ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le",
            "-x265-params", "pools=2:frame-threads=2:keyint=104:min-keyint=104:scenecut=0:open-gop=0:bframes=2:repeat-headers=1:log-level=error:\(colors)"]
            : ["-c:v", "libx264", "-g", "104", "-sc_threshold", "0", "-bf", "0"]
        generator.arguments = ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "color=c=blue:size=160x90:rate=10:duration=60",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=60",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=60",
            "-i", captions.path, "-i", chapters.path, "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-map_chapters", "4"]
            + video + ["-c:a:0", "ac3", "-ac:a:0", "2", "-c:a:1", "eac3", "-ac:a:1", "6", "-af", "asetpts=PTS+256/SR/TB",
                       "-metadata:s:a:0", "language=rus", "-metadata:s:a:1", "language=eng", "-c:s", "srt", movie.path]
        generator.standardInput = FileHandle.nullDevice
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let metadata = try await tools.probe(url: movie)
        XCTAssertGreaterThan(metadata.duration, 62)

        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("real-ffmpeg"), withDestinationURL: ffmpeg)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("ffprobe"), withDestinationURL: ffprobe)
        let shim = folder.appendingPathComponent("ffmpeg")
        try """
            #!/bin/sh
            set -e
            tools_dir="$(dirname "$0")"
            case " $* " in
              *" .rendered_%v.m3u8 "*)
                pwd > "$tools_dir/early-cache"
                mkdir -p .staged/.generated
                (cd .staged && "$tools_dir/real-ffmpeg" "$@")
                mv .staged/init_*.mp4 .
                if [ -f .staged/iframe-init.mp4 ]; then
                    mv .staged/iframe-init.mp4 .
                    mv .staged/.generated/iframe-000000.m4s .generated
                fi
                mv .staged/.generated/segment_*_000000.m4s .staged/.generated/segment_*_000001.m4s .generated
                attempts=0
                until [ -f "$tools_dir/finish-early" ]; do
                    attempts=$((attempts + 1))
                    [ "$attempts" -lt 200 ] || exit 1
                    sleep 0.05
                done
                mv .staged/.generated/*.m4s .generated
                mv .staged/.rendered_*.m3u8 .
                if [ -f .staged/.rendered-iframe.m3u8 ]; then mv .staged/.rendered-iframe.m3u8 .; fi
                exit 0 ;;
            esac
            exec "$tools_dir/real-ffmpeg" "$@"
            """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let suite = "app.beamly.early-hls-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(folder.path, forKey: "toolsDirectory")
        defaults.set("off", forKey: "preferredSubtitleLanguage")
        var queue = Playlist()
        queue.append([movie])
        queue.items[0].position = 35
        queue.items[0].duration = 60
        let state = folder.appendingPathComponent("queue.json")
        try JSONEncoder().encode(queue).write(to: state)
        let player = AirPlayTestPlayer()
        player.isMuted = true
        player.setExternalPlaybackActive(true)
        let model = AppModel(stateURL: state, defaults: defaults, player: player)
        defer { model.shutdown() }

        model.togglePlay()
        try await wait(diagnostic: model.errorMessage ?? model.playbackStatus) {
            player.timeControlStatus == .playing && !model.isPreparing
        }
        let earlyItem = try XCTUnwrap(player.currentItem)
        let cachePath = try String(contentsOf: folder.appendingPathComponent("early-cache"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cache = URL(fileURLWithPath: cachePath, isDirectory: true)
        let master = try String(contentsOf: cache.appendingPathComponent("master.m3u8"), encoding: .utf8)
        XCTAssertTrue(master.contains("VIDEO-RANGE=\(hdr ? "PQ" : "SDR")"))
        XCTAssertTrue(master.contains(hevc ? "hvc1.2." : "avc1."))
        XCTAssertTrue(master.contains("ac-3"))
        XCTAssertTrue(master.contains("ec-3"))
        let manifest = try String(contentsOf: cache.appendingPathComponent("stream_0.m3u8"), encoding: .utf8)
        let last = try XCTUnwrap(manifest.split(separator: "\n").last { $0.hasSuffix(".m4s") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(String(last)).path))
        XCTAssertTrue(manifest.contains("#EXT-X-ENDLIST"))
        XCTAssertEqual(player.currentTime().seconds, 35, accuracy: 0.6)
        XCTAssertEqual(earlyItem.duration.seconds, 60, accuracy: 0.1)
        XCTAssertEqual(model.duration, 60, accuracy: 0.1)
        let seekable = earlyItem.seekableTimeRanges.map { $0.timeRangeValue.end.seconds }.max() ?? 0
        XCTAssertEqual(seekable, 60, accuracy: 0.1)
        let captionsGroup = try await earlyItem.asset.loadMediaSelectionGroup(for: .legible)
        XCTAssertEqual(captionsGroup?.options.count, 1)
        let loadedAudio = try await earlyItem.asset.loadMediaSelectionGroup(for: .audible)
        let audioGroup = try XCTUnwrap(loadedAudio)
        XCTAssertEqual(audioGroup.options.count, 2)
        let english = try XCTUnwrap(audioGroup.options.first { MediaLanguages.normalized($0.extendedLanguageTag) == "en" })
        earlyItem.select(english, in: audioGroup)
        try await wait { model.audioID == 2 }
        XCTAssertTrue(player.currentItem === earlyItem)

        let lastSegment = cache.appendingPathComponent(String(last))
        model.seek(58)
        try await wait {
            FileManager.default.fileExists(atPath: lastSegment.path)
                && player.currentTime().seconds >= 58.15 && player.timeControlStatus == .playing
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(".rendered_0.m3u8").path))
        XCTAssertTrue(player.currentItem === earlyItem)
        let audioManifest = try String(contentsOf: cache.appendingPathComponent("stream_2.m3u8"), encoding: .utf8)
        let lastAudioName = try XCTUnwrap(audioManifest.split(separator: "\n").last { $0.hasSuffix(".m4s") })
        let lastAudio = cache.appendingPathComponent(String(lastAudioName))
        try await wait { FileManager.default.fileExists(atPath: lastAudio.path) }
        for (index, segment) in [(0, lastSegment), (2, lastAudio)] {
            let initialization = try Data(contentsOf: cache.appendingPathComponent("init_\(index).mp4"))
            let sequential = cache.appendingPathComponent(".staged/.generated").appendingPathComponent(segment.lastPathComponent)
            let probeInput = folder.appendingPathComponent("fragment.mp4")
            func packets(_ segment: URL) throws -> [Substring] {
                try (initialization + Data(contentsOf: segment)).write(to: probeInput)
                let probe = Process()
                let output = Pipe()
                probe.executableURL = ffprobe
                probe.arguments = ["-v", "error", "-show_entries", "packet=stream_index,pts,dts,duration,data_hash",
                                   "-show_data_hash", "sha256", "-of", "compact", probeInput.path]
                probe.standardOutput = output
                try probe.run()
                let rows = output.fileHandleForReading.readDataToEndOfFile()
                probe.waitUntilExit()
                XCTAssertEqual(probe.terminationStatus, 0)
                return String(decoding: rows, as: UTF8.self).split(separator: "\n").sorted()
            }
            XCTAssertTrue(try packets(segment) == packets(sequential), "Priority packets must match the sequential remux")
        }
        model.seek(0)
        try await wait { player.currentTime().seconds < 1 && player.timeControlStatus == .playing }

        try Data().write(to: folder.appendingPathComponent("finish-early"))
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: earlyItem)
        try await wait(diagnostic: model.errorMessage ?? "") {
            player.currentItem !== earlyItem && player.timeControlStatus == .playing && !model.isPreparing
        }
        XCTAssertTrue(model.isUsingHLS)
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertEqual(player.emptyReplacements, 0)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testAirPlaySelectionAtLaunchPlaysBothMoviesAcrossClearingTheQueue() async throws {
        let tools = mediaTestTools()
        let ffmpeg = try XCTUnwrap(tools.ffmpegURL)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-clear-route-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let suite = "app.beamly.clear-route.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(true, forKey: "autoPlay")
        defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
        let first = folder.appendingPathComponent("First.mp4")
        let second = folder.appendingPathComponent("Second.mkv")
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "color=c=blue:size=160x90:rate=24:duration=20",
            "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000:duration=20",
            "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-g", "24", "-c:a", "aac", "-movflags", "+faststart", first.path,
            "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-g", "24", "-c:a", "ac3", second.path]
        generator.standardInput = FileHandle.nullDevice
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)

        let player = AirPlayTestPlayer()
        player.losesRouteWhenEmptied = true
        let state = folder.appendingPathComponent("queue.json")
        let model = AppModel(stateURL: state, defaults: defaults, player: player)
        defer { model.shutdown() }
        let delegate = AppDelegate()
        delegate.mainWindowDidOpen(model)
        XCTAssertTrue(model.isAirPlayPickerRequested)
        model.isAirPlayPickerRequested = false
        model.airPlayPickerPresentationChanged(true)
        model.airPlayPickerPresentationChanged(false)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.playCalls, 0)
        player.activatesRouteDuringPreroll = true
        model.add([first])
        try await wait(diagnostic: model.errorMessage ?? model.playbackStatus) {
            model.isExternal && player.timeControlStatus == .playing && player.currentTime().seconds > 0.1
        }
        XCTAssertFalse(model.isAirPlayPickerRequested)
        XCTAssertEqual(player.prerollCalls, 1)
        player.activatesRouteDuringPreroll = false
        let oldItem = try XCTUnwrap(player.currentItem)
        let oldURL = try XCTUnwrap((oldItem.asset as? AVURLAsset)?.url)
        XCTAssertFalse(model.isUsingHLS)

        model.clear()
        XCTAssertTrue(model.playlist.items.isEmpty)
        XCTAssertNil(player.currentItem, "Apple TV must leave the movie player when clearing")
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(model.position, 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let oldResponse = try await session.data(from: oldURL).1
        XCTAssertEqual((oldResponse as? HTTPURLResponse)?.statusCode, 404, "The cleared movie must no longer be served")
        player.simulateTimeControl(.playing)
        try await wait { player.timeControlStatus == .paused }
        XCTAssertFalse(model.isPlaying, "The receiver must not resume a cleared movie")
        player.simulateTimeControl(nil)

        player.activatesRouteDuringMutedStart = true
        model.add([second])
        try await wait(diagnostic: model.errorMessage ?? model.playbackStatus) {
            model.current?.url == second && model.isExternal && player.timeControlStatus == .playing
                && !player.isMuted && player.currentTime().seconds > 0.1
        }
        XCTAssertTrue(model.isUsingHLS)
        XCTAssertEqual(player.emptyReplacements, 1)
        XCTAssertEqual(player.mutedLocalPlayCalls, 1)
        XCTAssertEqual(player.localPlayCalls, player.mutedLocalPlayCalls)
        XCTAssertFalse(model.isAirPlayPickerRequested)

        model.seek(5)
        try await wait { abs(player.currentTime().seconds - 5) < 0.5 }
        model.clear()
        player.activatesRouteDuringMutedStart = false
        model.add([second])
        try await wait { model.isConnectingAirPlay && player.isMuted }
        try await wait { model.isAirPlayPickerRequested }
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.isConnectingAirPlay)
        XCTAssertFalse(player.isMuted, "A failed restart must restore the original mute setting")
        XCTAssertEqual(player.rate, 0)
        try await wait { abs(player.currentTime().seconds - 5) < 0.5 }
        XCTAssertEqual(model.position, 5, accuracy: 0.5)
        XCTAssertEqual(player.mutedLocalPlayCalls, 2)
        XCTAssertEqual(player.localPlayCalls, player.mutedLocalPlayCalls, "No video may start with sound on the Mac")

        model.isAirPlayPickerRequested = false
        model.airPlayPickerPresentationChanged(true)
        player.setExternalPlaybackActive(true)
        model.airPlayPickerPresentationChanged(false)
        try await wait { model.isExternal && player.timeControlStatus == .playing }

        model.shutdown()
        XCTAssertNil(player.currentItem)
    }

    @MainActor
    func testSelectedAirPlayRouteSurvivesStartTrackChangesAndReconnection() async throws {
        let tools = mediaTestTools()
        let ffmpeg = try XCTUnwrap(tools.ffmpegURL)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-route-handoff-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movie = folder.appendingPathComponent("Movie.mkv")
        let movieWithoutCaptions = folder.appendingPathComponent("Movie without captions.mkv")
        let movieWithAlternateAudio = folder.appendingPathComponent("Movie with alternate audio.mkv")
        let captions = folder.appendingPathComponent("captions.srt")
        try "1\n00:00:00,500 --> 00:00:29,000\nRoute handoff caption\n".write(to: captions, atomically: true, encoding: .utf8)
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=blue:size=160x90:rate=10:duration=30",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=30", "-f", "lavfi", "-i", "sine=frequency=880:duration=30", "-i", captions.path,
            "-f", "lavfi", "-i", "sine=frequency=660:duration=30",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-map", "3:s", "-map", "4:a", "-c:v", "libx264", "-g", "10", "-bf", "0",
            "-c:a:0", "eac3", "-ac:a:0", "6", "-c:a:1", "aac", "-c:a:2", "eac3", "-ac:a:2", "6", "-c:s", "srt",
            "-metadata:s:a:0", "language=rus", "-metadata:s:a:2", "language=eng",
            "-metadata:s:s:0", "language=rus", "-metadata:s:s:1", "language=rus",
            "-metadata:s:s:0", "title=Russian \"Captions\"", "-metadata:s:s:1", "title=Russian \"Captions\"", movie.path]
        generator.standardInput = FileHandle.nullDevice
        generator.standardOutput = FileHandle.nullDevice
        generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let remux = Process()
        remux.executableURL = ffmpeg
        remux.arguments = ["-v", "error", "-nostdin", "-i", movie.path,
            "-map", "0:v", "-map", "0:a:0", "-map", "0:a:1", "-c", "copy", movieWithoutCaptions.path,
            "-map", "0:v", "-map", "0:a:0", "-map", "0:a:2", "-c", "copy", movieWithAlternateAudio.path]
        remux.standardOutput = FileHandle.nullDevice
        remux.standardError = FileHandle.nullDevice
        try remux.run(); remux.waitUntilExit()
        XCTAssertEqual(remux.terminationStatus, 0)
        let original = try Data(contentsOf: movie)
        let suite = "app.beamly.route-handoff.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
        var playlist = Playlist()
        playlist.append([movieWithoutCaptions, movie, movieWithAlternateAudio]); playlist.items[0].position = 8; playlist.items[0].duration = 30
        let state = folder.appendingPathComponent("queue.json")
        try JSONEncoder().encode(playlist).write(to: state)
        let player = AirPlayTestPlayer()
        player.isMuted = true
        player.losesRouteWhenEmptied = true
        let model = AppModel(stateURL: state, defaults: defaults, player: player)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var pickerRequests = 0
        let observation = model.$isAirPlayPickerRequested.sink { if $0 { pickerRequests += 1 } }
        defer { observation.cancel() }
        func readyAndPlaying() -> Bool { !model.isPreparing && player.currentItem?.status == .readyToPlay && player.rate > 0 && model.isPlaying }

        // A startup selection may only become active once the first movie is ready.
        model.airPlayPickerPresentationChanged(true)
        model.airPlayPickerPresentationChanged(false)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.playCalls, 0)
        player.activatesRouteDuringPreroll = true
        model.togglePlay()
        XCTAssertTrue(model.isPreparing)
        XCTAssertFalse(model.isAirPlayPickerRequested)
        model.togglePlay()
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(model.position, 8, "Cancelling preparation must keep the resume position")
        model.togglePlay()
        try await wait(diagnostic: model.errorMessage ?? "") { readyAndPlaying() }
        XCTAssertEqual(player.emptyReplacements, 0, "Starting must not clear a receiver selected before loading a movie")
        XCTAssertEqual(model.position, 8, accuracy: 1)
        let resumedItem = try XCTUnwrap(player.currentItem)
        XCTAssertEqual((resumedItem.asset as? AVURLAsset)?.url.pathExtension, "mp4")
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertEqual(model.audioOptions.map(\.id), [1, 2])
        XCTAssertTrue(model.subtitleOptions.isEmpty)
        let resumedDuration = try await resumedItem.asset.load(.duration).seconds
        XCTAssertEqual(resumedDuration, 30, accuracy: 0.3, "Resuming must publish the entire movie, including the first eight seconds")
        XCTAssertEqual(player.currentTime().seconds, 8, accuracy: 1)
        model.togglePlay()
        try await wait { !model.isPlaying }
        let prerolls = player.prerollCalls
        player.setExternalPlaybackActive(false)
        try await wait { !model.isExternal }
        model.togglePlay()
        try await wait { readyAndPlaying() }
        XCTAssertGreaterThan(player.prerollCalls, prerolls, "A paused selected route can become active during rate-zero preparation")

        player.resetsRouteOnReplacement = true
        let fallbackPosition = model.position
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: resumedItem)
        try await wait(diagnostic: model.errorMessage ?? "") { readyAndPlaying() && model.isUsingHLS }
        XCTAssertEqual(model.position, fallbackPosition, accuracy: 1.5, "The HLS fallback resumes the same movie position")
        XCTAssertNil(model.errorMessage)

        model.select(playlist.items[1].id, resumeAt: fallbackPosition)
        try await wait(diagnostic: model.errorMessage ?? "") { readyAndPlaying() && model.isUsingHLS }
        XCTAssertEqual(model.subtitleOptions.map(\.id), [3, 4])
        let captionedItem = try XCTUnwrap(player.currentItem)
        let dolbyURL = try XCTUnwrap((captionedItem.asset as? AVURLAsset)?.url)
        let dolbyMaster = String(decoding: try await session.data(from: dolbyURL).0, as: UTF8.self)
        XCTAssertTrue(dolbyMaster.contains(",ec-3\""))
        XCTAssertFalse(dolbyMaster.contains("mp4a"))
        XCTAssertEqual(dolbyMaster.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO,") }.count, 2)
        XCTAssertEqual(model.audioOptions.map(\.id), [1, 2, 5])
        let loadedAudioGroup = try await captionedItem.asset.loadMediaSelectionGroup(for: .audible)
        let audioGroup = try XCTUnwrap(loadedAudioGroup)
        func activeLanguage() -> String? {
            MediaLanguages.normalized(captionedItem.currentMediaSelection.selectedMediaOption(in: audioGroup)?.extendedLanguageTag)
        }
        XCTAssertEqual(activeLanguage(), "ru")
        model.setAudio(5)
        try await wait { activeLanguage() == "en" }
        XCTAssertTrue(player.currentItem === captionedItem)
        model.setAudio(nil)
        try await wait { activeLanguage() == "ru" }
        XCTAssertNil(model.audioID)
        model.togglePlay()
        try await wait { !model.isPlaying }
        let receiverChoice = try XCTUnwrap(audioGroup.options.first { MediaLanguages.normalized($0.extendedLanguageTag) == "en" })
        captionedItem.select(receiverChoice, in: audioGroup)
        try await wait { model.audioID == 5 }
        let fileDefault = try XCTUnwrap(audioGroup.defaultOption)
        captionedItem.select(fileDefault, in: audioGroup)
        try await wait { model.audioID == 1 }
        captionedItem.select(receiverChoice, in: audioGroup)
        try await wait { model.audioID == 5 }
        XCTAssertTrue(player.currentItem === captionedItem)
        let loadedCaptionGroup = try await captionedItem.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedCaptionGroup)
        XCTAssertEqual(group.options.count, 2)
        XCTAssertNil(captionedItem.currentMediaSelection.selectedMediaOption(in: group))
        model.setSubtitle(3)
        try await wait { captionedItem.currentMediaSelection.selectedMediaOption(in: group) != nil }
        let first = try XCTUnwrap(captionedItem.currentMediaSelection.selectedMediaOption(in: group))
        let identifier = AVMetadataIdentifier(rawValue: "m3u8/NAME")
        let name = try await AVMetadataItem.metadataItems(from: first.commonMetadata, filteredByIdentifier: identifier).first?.load(.stringValue)
        XCTAssertEqual(name, "Russian 'Captions'")
        XCTAssertTrue(player.currentItem === captionedItem)
        let alternate = try XCTUnwrap(group.options.first { $0 != first })
        captionedItem.select(alternate, in: group)
        try await wait { model.subtitleID == 4 }
        captionedItem.select(nil, in: group)
        try await wait { model.subtitleID == nil }
        captionedItem.select(alternate, in: group)
        try await wait { model.subtitleID == 4 }
        XCTAssertTrue(player.currentItem === captionedItem)
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(player.rate, 0)
        model.togglePlay()
        try await wait { readyAndPlaying() }

        let dolbyPosition = model.position
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: captionedItem)
        try await wait(diagnostic: model.errorMessage ?? "") { readyAndPlaying() && player.currentItem !== captionedItem }
        let stereoItem = try XCTUnwrap(player.currentItem)
        let stereoURL = try XCTUnwrap((stereoItem.asset as? AVURLAsset)?.url)
        let stereoMaster = String(decoding: try await session.data(from: stereoURL).0, as: UTF8.self)
        XCTAssertTrue(stereoMaster.contains(",mp4a.40.2\""))
        XCTAssertFalse(stereoMaster.contains("ec-3"))
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertEqual(model.position, dolbyPosition, accuracy: 1.5)
        XCTAssertEqual(model.audioID, 5)
        XCTAssertEqual(model.subtitleID, 4)
        let stereoCaptions = try await stereoItem.asset.loadMediaSelectionGroup(for: .legible)
        XCTAssertNotNil(stereoItem.currentMediaSelection.selectedMediaOption(in: try XCTUnwrap(stereoCaptions)))

        let oldItem = try XCTUnwrap(player.currentItem)
        let oldURL = try XCTUnwrap((oldItem.asset as? AVURLAsset)?.url)
        let position = model.position
        model.setAudio(2)
        XCTAssertTrue(player.currentItem === oldItem, "Keep the routed item attached while preparing the replacement")
        let (_, oldResponse) = try await session.data(from: oldURL)
        XCTAssertEqual((oldResponse as? HTTPURLResponse)?.statusCode, 200, "The old receiver URL must remain available during preparation")
        try await wait(diagnostic: model.errorMessage ?? "") { readyAndPlaying() }
        XCTAssertEqual(model.audioID, 2)
        XCTAssertEqual(model.subtitleID, 4, "Replacing audio must retain the caption selected by the receiver")
        XCTAssertEqual(model.position, position, accuracy: 1.5)
        XCTAssertEqual(player.emptyReplacements, 0)
        let retiredResponse = try? await session.data(from: oldURL).1
        XCTAssertNotEqual((retiredResponse as? HTTPURLResponse)?.statusCode, 200, "Retire the previous stream after handoff")

        model.setSubtitle(3)
        model.setAudio(1)
        try await wait(diagnostic: model.errorMessage ?? "") { readyAndPlaying() }
        XCTAssertEqual(model.audioID, 1)
        XCTAssertEqual(model.subtitleID, 3, "Rapid replacements retain both manual choices and play intent")
        let loadedGroup = try await player.currentItem?.asset.loadMediaSelectionGroup(for: .legible)
        let reloadedGroup = try XCTUnwrap(loadedGroup)
        XCTAssertNotNil(player.currentItem?.currentMediaSelection.selectedMediaOption(in: reloadedGroup))
        let routedItem = try XCTUnwrap(player.currentItem)
        // Seek through AVPlayer, as a receiver would, without asking Beamly to rebuild the stream.
        let rewound = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(rewound)
        try await wait(diagnostic: model.errorMessage ?? "") { readyAndPlaying() && model.position < 1 }
        XCTAssertTrue(player.currentItem === routedItem)
        model.togglePlay()
        try await wait { !model.isPlaying }
        model.setSubtitle(nil)
        try await wait { routedItem.currentMediaSelection.selectedMediaOption(in: reloadedGroup) == nil }
        XCTAssertTrue(player.currentItem === routedItem)
        XCTAssertEqual(player.rate, 0, "Changing captions while paused must stay paused")
        model.togglePlay()
        try await wait { readyAndPlaying() }
        XCTAssertEqual(pickerRequests, 0)
        XCTAssertEqual(player.localPlayCalls, 0)

        player.setExternalPlaybackActive(false)
        try await wait { !model.isPlaying && !model.isExternal }
        let calls = player.playCalls
        player.setExternalPlaybackActive(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.playCalls, calls, "A real disconnection cancels play intent")
        model.togglePlay()
        try await wait { readyAndPlaying() }
        model.select(playlist.items[2].id)
        try await wait { readyAndPlaying() }
        XCTAssertTrue(model.isUsingHLS, "An MKV with alternate audio needs HLS even when it has no captions")
        let audioOnlyGroup = try await player.currentItem?.asset.loadMediaSelectionGroup(for: .audible)
        XCTAssertEqual(audioOnlyGroup?.options.count, 2)
        model.setAudioDelay(0.5)
        model.stop()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(model.isPreparing)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.isAirPlayPickerRequested)
        XCTAssertEqual(player.localPlayCalls, 0)
        XCTAssertEqual(try Data(contentsOf: movie), original)
    }

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
        player.isMuted = true
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
        model.togglePlay()
        XCTAssertTrue(model.isPreparing)
        XCTAssertTrue(model.isAirPlayPickerRequested, "Play must ask for a receiver before the item is ready")
        XCTAssertEqual(player.playCalls, 0)
        model.togglePlay()
        XCTAssertFalse(model.isAirPlayPickerRequested)

        model.select(saved.items[0].id, autoPlay: false)
        try await wait { model.player.currentItem?.status == .readyToPlay && !model.isPreparing }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isUsingHLS)
        XCTAssertEqual(model.audioOptions.count, 2)
        player.isMuted = true
        // Neither a manual request nor automatic preparation may play locally.
        let pausedTime = player.currentTime().seconds
        model.togglePlay()
        XCTAssertTrue(model.isAirPlayPickerRequested)
        XCTAssertEqual(player.playCalls, 0)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(model.errorMessage)
        model.togglePlay()
        XCTAssertFalse(model.isAirPlayPickerRequested, "Pause cancels the pending picker request")
        model.togglePlay()
        XCTAssertTrue(model.isAirPlayPickerRequested)
        model.isAirPlayPickerRequested = false
        model.airPlayPickerPresentationChanged(true)
        XCTAssertEqual(player.prerollCalls, 0)
        model.airPlayPickerPresentationChanged(false)
        XCTAssertEqual(player.prerollCalls, 1, "Prime the player after a possible receiver selection")
        XCTAssertFalse(model.isPlaying, "Play must remain available until the receiver is confirmed")
        let preparedItem = try XCTUnwrap(player.currentItem)
        model.togglePlay()
        XCTAssertTrue(model.isAirPlayPickerRequested, "Pressing Play again after dismissal must open the picker immediately")
        XCTAssertFalse(model.isConnectingAirPlay)
        XCTAssertTrue(player.currentItem === preparedItem)
        XCTAssertEqual(player.prerollCalls, 1)
        XCTAssertEqual(player.playCalls, 0)
        model.isAirPlayPickerRequested = false
        model.airPlayPickerPresentationChanged(true)
        model.airPlayPickerPresentationChanged(false)
        try await Task.sleep(for: .seconds(3.1))
        XCTAssertFalse(model.isAirPlayPickerRequested, "Dismissing the picker must not reopen it for the same Play request")
        XCTAssertEqual(player.currentTime().seconds, pausedTime, accuracy: 0.1, "Preroll must not advance the movie without a receiver")
        model.select(saved.items[0].id)
        try await wait { !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(player.playCalls, 0)
        player.setExternalPlaybackActive(true)
        try await wait { model.isPlaying }
        model.togglePlay()
        try await wait { !model.isPlaying }
        model.airPlayPickerPresentationChanged(true)
        player.setExternalPlaybackActive(false)
        try await wait { !model.isPlaying && !model.isExternal }
        model.airPlayPickerPresentationChanged(false)
        XCTAssertEqual(player.rate, 0)
        let callsAfterDisconnect = player.playCalls
        model.togglePlay()
        XCTAssertEqual(player.playCalls, callsAfterDisconnect)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isAirPlayPickerRequested, "Deselecting a paused receiver must also allow an immediate retry")
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
        let defaultAudio = try XCTUnwrap(nativeItem.currentMediaSelection.selectedMediaOption(in: audioGroup))
        let defaultTrack = try XCTUnwrap(model.audioOptions.first { $0.title == defaultAudio.displayName })
        let otherAudio = try XCTUnwrap(audioGroup.options.first { $0.displayName == secondAudio.title })
        nativeItem.select(otherAudio, in: audioGroup)
        try await wait { model.audioID == secondAudio.id }
        nativeItem.select(defaultAudio, in: audioGroup)
        try await wait { model.audioID == defaultTrack.id }

        let nativeCaptionGroup = try await nativeItem.asset.loadMediaSelectionGroup(for: .legible)
        let nativeCaptions = try XCTUnwrap(nativeCaptionGroup)
        let caption = try XCTUnwrap(nativeCaptions.options.first { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) })
        let captionTrack = try XCTUnwrap(model.subtitleOptions.first)
        nativeItem.select(caption, in: nativeCaptions)
        try await wait { model.subtitleID == captionTrack.id }
        nativeItem.select(nil, in: nativeCaptions)
        try await wait { model.subtitleID == nil }
        XCTAssertTrue(player.currentItem === nativeItem)
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(player.rate, 0)

        model.add([subtitle])
        try await wait(diagnostic: model.errorMessage ?? "no player error") { model.isUsingHLS && !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.externalSubtitle, subtitle)
        let embedded = try XCTUnwrap(model.subtitleOptions.first)
        let restoredItem = try XCTUnwrap(model.player.currentItem)
        let loadedCaptions = try await restoredItem.asset.loadMediaSelectionGroup(for: .legible)
        let captions = try XCTUnwrap(loadedCaptions)
        let externalOption = restoredItem.currentMediaSelection.selectedMediaOption(in: captions)
        XCTAssertNotNil(externalOption)
        model.setSubtitle(embedded.id)
        try await wait { restoredItem.currentMediaSelection.selectedMediaOption(in: captions) != externalOption }
        XCTAssertTrue(model.player.currentItem === restoredItem)
        XCTAssertFalse(model.isPreparing)
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
        XCTAssertNil(player.currentItem, "A cancelled load must not attach an item after clearing")
        XCTAssertEqual(player.rate, 0)
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
    func testNativeForcedSubtitleVariantsKeepSourceStreamIDsAfterHLSRebuild() async throws {
        let tools = mediaTestTools()
        guard let ffmpeg = tools.ffmpegURL, tools.ffprobeURL != nil else { throw XCTSkip("FFmpeg is required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-forced-track-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "app.beamly.forced-track.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoPlay")
        defaults.set(ffmpeg.deletingLastPathComponent().path, forKey: "toolsDirectory")
        defaults.set("ru", forKey: "preferredSubtitleLanguage")
        let caption = folder.appendingPathComponent("captions.srt")
        try "1\n00:00:00,500 --> 00:00:05,500\nFull or forced caption\n".write(to: caption, atomically: true, encoding: .utf8)
        let video = folder.appendingPathComponent("Movie.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=blue:size=160x90:rate=24:duration=6",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-i", caption.path,
            "-map", "0:v", "-map", "1:a", "-map", "2:s", "-map", "2:s", "-c:v", "libx264", "-c:a", "aac", "-c:s", "mov_text",
            "-metadata:s:s:0", "language=rus", "-metadata:s:s:1", "language=rus",
            "-disposition:s:0", "forced", "-disposition:s:1", "default", "-movflags", "+faststart", video.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let model = AppModel(stateURL: folder.appendingPathComponent("queue.json"), defaults: defaults, player: AirPlayTestPlayer())
        defer { model.shutdown() }
        model.add([video])
        try await wait(diagnostic: model.errorMessage ?? "no player error") { !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertFalse(model.isUsingHLS)
        XCTAssertEqual(model.subtitleOptions.map(\.id), [2, 3], "Native forced-only aliases must not become extra source streams")
        XCTAssertEqual(model.subtitleID, 3, "Prefer full captions of the requested language")
        guard model.subtitleID == 3 else { return }
        model.setSubtitleDelay(0.5)
        try await wait(diagnostic: model.errorMessage ?? "no player error") { !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(model.isUsingHLS)
        XCTAssertTrue(model.isVideoCopied)
        XCTAssertEqual(model.subtitleID, 3)
        model.setSubtitle(2)
        model.setSubtitleDelay(0)
        try await wait(diagnostic: model.errorMessage ?? "no player error") { !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertFalse(model.isUsingHLS)
        XCTAssertEqual(model.subtitleID, 2, "A physical forced track remains available for manual selection")
        model.setSubtitleDelay(-0.5)
        try await wait(diagnostic: model.errorMessage ?? "no player error") { !model.isPreparing && model.player.currentItem?.status == .readyToPlay }
        XCTAssertEqual(model.subtitleID, 2)
        XCTAssertNil(model.errorMessage)
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
final class AirPlayTestPlayer: AVPlayer, @unchecked Sendable {
    private let lock = NSLock()
    private var external = false
    private var simulatedStatus: AVPlayer.TimeControlStatus?
    private var simulatedReason: AVPlayer.WaitingReason?
    private(set) var playCalls = 0
    private(set) var localPlayCalls = 0
    private(set) var mutedLocalPlayCalls = 0
    private(set) var emptyReplacements = 0
    private(set) var prerollCalls = 0
    var losesRouteWhenEmptied = false
    var resetsRouteOnReplacement = false
    var activatesRouteDuringPreroll = false
    var activatesRouteDuringMutedStart = false
    private(set) var lastConfiguredItem: AVPlayerItem?

    override func replaceCurrentItem(with item: AVPlayerItem?) {
        if let item { lastConfiguredItem = item }
        else { emptyReplacements += 1 }
        if item == nil && losesRouteWhenEmptied || item != nil && resetsRouteOnReplacement {
            setExternalPlaybackActive(false)
        }
        super.replaceCurrentItem(with: item)
    }

    override func preroll(atRate rate: Float, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        prerollCalls += 1
        if activatesRouteDuringPreroll { setExternalPlaybackActive(true) }
        super.preroll(atRate: rate, completionHandler: completionHandler)
    }

    override var isExternalPlaybackActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return external
    }

    override var timeControlStatus: AVPlayer.TimeControlStatus {
        lock.lock()
        let status = simulatedStatus
        lock.unlock()
        return status ?? super.timeControlStatus
    }

    override var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        lock.lock()
        let active = simulatedStatus != nil
        let reason = simulatedReason
        lock.unlock()
        return active ? reason : super.reasonForWaitingToPlay
    }

    func simulateTimeControl(_ status: AVPlayer.TimeControlStatus?, reason: AVPlayer.WaitingReason? = nil) {
        lock.lock()
        let changedStatus = simulatedStatus != status
        lock.unlock()
        if changedStatus { willChangeValue(forKey: "timeControlStatus") }
        willChangeValue(forKey: "reasonForWaitingToPlay")
        lock.lock()
        simulatedStatus = status
        simulatedReason = reason
        lock.unlock()
        didChangeValue(forKey: "reasonForWaitingToPlay")
        if changedStatus { didChangeValue(forKey: "timeControlStatus") }
    }

    override func pause() {
        lock.lock()
        let simulated = simulatedStatus != nil
        lock.unlock()
        if simulated { simulateTimeControl(.paused) }
        super.pause()
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
        if !isExternalPlaybackActive {
            localPlayCalls += 1
            if isMuted {
                mutedLocalPlayCalls += 1
                if activatesRouteDuringMutedStart { setExternalPlaybackActive(true) }
            }
        }
        super.play()
    }
}
