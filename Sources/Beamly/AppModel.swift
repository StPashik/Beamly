import AppKit
import AVKit
import Combine
import MediaPlayer
import BeamlyCore
import SwiftUI
import UniformTypeIdentifiers

struct TrackOption: Identifiable {
    let id: Int
    let title: String
}

@MainActor
/// Owns playback and playlist state; UI and AVFoundation callbacks meet on the main actor.
final class AppModel: ObservableObject {
    @Published private(set) var playlist = Playlist()
    @Published private(set) var info: MediaInfo?
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isExternal = false
    @Published private(set) var routesDetected = false
    @Published private(set) var isTranscoding = false
    @Published private(set) var audioOptions: [TrackOption] = []
    @Published private(set) var subtitleOptions: [TrackOption] = []
    @Published private(set) var audioID: Int?
    @Published private(set) var subtitleID: Int?
    @Published private(set) var externalSubtitle: URL?
    @Published var errorMessage: String?
    @Published var volume = 1.0 { didSet { player.volume = Float(volume) } }

    // Keep one player when changing files so AVKit retains the selected AirPlay route.
    let player = AVPlayer()
    private let server = MediaHTTPServer()
    private let routeDetector = AVRouteDetector()
    private var job: HLSJob?
    private var preparation: Task<Void, Never>?
    private var loadID = UUID()
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    // HLS starts at local time zero; the UI still shows the position in the original movie.
    private var sourceOffset = 0.0
    private var lastSavedSecond = -1
    private var activity: NSObjectProtocol?
    private var directAudioGroup: AVMediaSelectionGroup?
    private var directSubtitleGroup: AVMediaSelectionGroup?
    private var directAudioChoices: [Int: AVMediaSelectionOption] = [:]
    private var directSubtitleChoices: [Int: AVMediaSelectionOption] = [:]

    private let stateURL: URL
    private let defaults: UserDefaults
    private var tools: FFmpegTools {
        let path = defaults.string(forKey: "toolsDirectory") ?? ""
        return FFmpegTools(customDirectory: path.isEmpty ? nil : URL(fileURLWithPath: path))
    }

    init(stateURL: URL? = nil, defaults: UserDefaults = .standard) {
        // Keep the original data location so renaming the app preserves the queue.
        self.stateURL = stateURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Peamer/playlist.json")
        self.defaults = defaults
        defaults.register(defaults: ["autoPlay": true, "directPlayback": true, "hardwareEncoding": true, "appearance": "system"])
        restore()
        duration = playlist.current?.duration ?? 0
        position = playlist.current?.position ?? 0
        player.allowsExternalPlayback = true
        routeDetector.isRouteDetectionEnabled = true
        observations = [
            player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor in self?.isExternal = player.isExternalPlaybackActive }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPlaying = player.timeControlStatus != .paused
                    self.updateActivity()
                    self.updateNowPlaying()
                }
            },
            routeDetector.observe(\.multipleRoutesDetected, options: [.initial, .new]) { [weak self] detector, _ in
                Task { @MainActor in self?.routesDetected = detector.multipleRoutesDetected }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isPreparing, self.player.currentItem != nil, time.seconds.isFinite else { return }
                if let diagnostic = self.job?.diagnostic {
                    self.errorMessage = diagnostic
                    self.remember()
                    self.cancelPlayback()
                    return
                }
                self.position = min(self.duration, max(0, self.sourceOffset + time.seconds))
                self.playlist.remember(position: self.position, duration: self.duration)
                let second = Int(self.position)
                if second % 5 == 0 && second != self.lastSavedSecond {
                    self.lastSavedSecond = second
                    self.save()
                    self.updateNowPlaying()
                }
            }
        }
        configureRemoteCommands()
    }

    var current: PlaylistItem? { playlist.current }
    var networkAddress: String { server.host }
    var status: String {
        if isPreparing { return NSLocalizedString("Preparing video…", comment: "") }
        if isExternal { return isPlaying ? NSLocalizedString("Playing via AirPlay", comment: "") : NSLocalizedString("AirPlay connected", comment: "") }
        return routesDetected ? NSLocalizedString("AirPlay devices available", comment: "") : NSLocalizedString("Choose an Apple TV or AirPlay TV", comment: "")
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Add videos", comment: "")
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = NSLocalizedString("Add", comment: "")
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        Task {
            let videos = await Task.detached(priority: .userInitiated) {
                let extensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpeg", "mpg", "m2ts", "mts", "ts", "m2t", "vob", "flv", "wmv", "ogm", "ogg", "rmvb", "divx", "3gp"]
                var result: [URL] = []
                for url in urls where url.isFileURL {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                        while let child = iterator?.nextObject() as? URL {
                            if extensions.contains(child.pathExtension.lowercased()), (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.append(child) }
                        }
                    } else if extensions.contains(url.pathExtension.lowercased()) {
                        result.append(url)
                    }
                }
                return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }.value
            let wasEmpty = playlist.items.isEmpty
            playlist.append(videos)
            save()
            if wasEmpty, let id = playlist.currentID { select(id, autoPlay: defaults.bool(forKey: "autoPlay")) }
            if videos.isEmpty, let subtitle = urls.first(where: { ["srt", "ass", "ssa", "vtt"].contains($0.pathExtension.lowercased()) }) {
                attachSubtitle(subtitle)
            } else if videos.isEmpty { errorMessage = NSLocalizedString("The selected files contain no supported videos.", comment: "") }
        }
    }

    func select(_ id: UUID, autoPlay: Bool = true) {
        guard playlist.items.contains(where: { $0.id == id }) else { return }
        remember()
        cancelPlayback()
        playlist.currentID = id
        info = nil
        audioID = nil
        subtitleID = nil
        externalSubtitle = nil
        audioOptions = []
        subtitleOptions = []
        position = playlist.current?.position ?? 0
        duration = playlist.current?.duration ?? 0
        save()
        prepare(at: duration > 0 && position > duration - 3 ? 0 : position, autoPlay: autoPlay)
    }

    func togglePlay() {
        if isPreparing { stop(); return }
        if player.currentItem == nil {
            if let id = playlist.currentID { select(id) } else { openFiles() }
        } else if isPlaying { player.pause(); remember() }
        else if duration > 0 && position >= duration - 0.5 { seek(0); player.play() }
        else { player.play() }
    }

    func stop() {
        cancelPlayback()
        position = 0
        playlist.remember(position: 0, duration: duration)
        save()
        updateNowPlaying()
    }

    func next() { if let id = playlist.next() { select(id) } }
    func previous() {
        if position > 3 { seek(0) }
        else if let id = playlist.previous() { select(id) }
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let target = min(max(0, seconds), max(0, duration - 0.05))
        position = target
        if isTranscoding {
            let local = target - sourceOffset
            let seekable = player.currentItem?.seekableTimeRanges.contains { CMTimeRangeContainsTime($0.timeRangeValue, time: CMTime(seconds: local, preferredTimescale: 600)) } == true
            if local < 0 || !seekable { prepare(at: target, autoPlay: isPlaying); return }
        }
        player.seek(to: CMTime(seconds: max(0, target - sourceOffset), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        remember()
        updateNowPlaying()
    }

    func setAudio(_ id: Int?) {
        audioID = id
        if let group = directAudioGroup, !isTranscoding {
            if let id { player.currentItem?.select(directAudioChoices[id], in: group) }
            else { player.currentItem?.selectMediaOptionAutomatically(in: group) }
        } else { prepare(at: position, autoPlay: isPlaying) }
    }

    func setSubtitle(_ id: Int?) {
        subtitleID = id
        externalSubtitle = nil
        if let group = directSubtitleGroup, !isTranscoding {
            player.currentItem?.select(id.flatMap { directSubtitleChoices[$0] }, in: group)
        } else { prepare(at: position, autoPlay: isPlaying) }
    }

    func chooseSubtitle() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose subtitles", comment: "")
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { attachSubtitle(url) }
    }

    private func attachSubtitle(_ url: URL) {
        guard current != nil else { errorMessage = NSLocalizedString("Add a video first.", comment: ""); return }
        externalSubtitle = url
        subtitleID = nil
        prepare(at: position, autoPlay: isPlaying)
    }

    func remove(_ id: UUID) {
        // Removing a queue entry never removes the movie from disk.
        let active = id == playlist.currentID
        if active { cancelPlayback() }
        playlist.remove(id)
        save()
        if active {
            position = playlist.current?.position ?? 0
            duration = playlist.current?.duration ?? 0
            if let next = playlist.currentID { select(next, autoPlay: false) }
            else { info = nil; position = 0; duration = 0 }
        }
    }

    func clear() {
        cancelPlayback()
        playlist.items.removeAll()
        playlist.currentID = nil
        info = nil
        duration = 0
        position = 0
        save()
        updateNowPlaying()
    }

    func move(from offsets: IndexSet, to destination: Int) { playlist.items.move(fromOffsets: offsets, toOffset: destination); save() }
    func toggleShuffle() { playlist.shuffle.toggle(); save() }
    func setRepeat(_ mode: RepeatMode) { playlist.repeatMode = mode; save() }

    private func prepare(at start: Double, autoPlay: Bool) {
        guard let movie = current else { return }
        cancelPlayback()
        // Cancellation is cooperative; this ID also rejects callbacks from an older load.
        let generation = loadID
        let start = max(0, start)
        isPreparing = true
        position = start
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                guard FileManager.default.isReadableFile(atPath: movie.url.path) else { throw PlaybackError(String(format: NSLocalizedString("File not found or inaccessible: %@", comment: ""), movie.url.lastPathComponent)) }
                let asset = AVURLAsset(url: movie.url)
                let metadata: MediaInfo
                do { metadata = try await tools.probe(url: movie.url) }
                catch {
                    try Task.checkCancellation()
                    guard ["mp4", "m4v", "mov"].contains(movie.url.pathExtension.lowercased()), (try? await asset.load(.isPlayable)) == true else { throw error }
                    metadata = MediaInfo(duration: try await asset.load(.duration).seconds, width: 0, height: 0, videoCodec: nil, audioTracks: [], subtitleTracks: [])
                }
                try Task.checkCancellation()
                guard loadID == generation else { return }
                info = metadata
                duration = metadata.duration.isFinite ? max(0, metadata.duration) : 0
                var canPlayDirect = false
                if ["mp4", "m4v", "mov"].contains(movie.url.pathExtension.lowercased()), externalSubtitle == nil, defaults.bool(forKey: "directPlayback") {
                    canPlayDirect = (try? await asset.load(.isPlayable)) == true
                }
                try Task.checkCancellation()
                try await server.start()
                try Task.checkCancellation()
                let playbackURL: URL
                if canPlayDirect {
                    isTranscoding = false
                    sourceOffset = 0
                    playbackURL = try server.publish(file: movie.url)
                } else {
                    isTranscoding = true
                    sourceOffset = start
                    audioOptions = metadata.audioTracks.map { TrackOption(id: $0.id, title: self.trackTitle($0)) }
                    subtitleOptions = metadata.subtitleTracks.map { TrackOption(id: $0.id, title: self.trackTitle($0)) }
                    let newJob = HLSJob(tools: tools)
                    job = newJob
                    let choice: SubtitleChoice = externalSubtitle.map { .external($0) } ?? subtitleID.map { .embedded($0) } ?? .none
                    let playlistURL = try await newJob.start(input: movie.url, info: metadata, audioTrack: audioID, subtitle: choice, startTime: start, hardwareEncoding: defaults.bool(forKey: "hardwareEncoding"))
                    try Task.checkCancellation()
                    playbackURL = try server.publish(directory: playlistURL.deletingLastPathComponent(), playlist: playlistURL.lastPathComponent)
                }
                try Task.checkCancellation()
                guard loadID == generation else { return }
                let item = AVPlayerItem(url: playbackURL)
                if !isTranscoding {
                    // Select tracks from the streamed asset, whose groups belong to this player item.
                    let audioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
                    let subtitleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
                    try Task.checkCancellation()
                    guard loadID == generation else { return }
                    directAudioGroup = audioGroup
                    directSubtitleGroup = subtitleGroup
                    audioOptions = (audioGroup?.options ?? []).enumerated().map { index, option in
                        let id = metadata.audioTracks.indices.contains(index) ? metadata.audioTracks[index].id : index
                        self.directAudioChoices[id] = option
                        return TrackOption(id: id, title: option.displayName)
                    }
                    subtitleOptions = (subtitleGroup?.options ?? []).enumerated().map { index, option in
                        let id = metadata.subtitleTracks.indices.contains(index) ? metadata.subtitleTracks[index].id : index
                        self.directSubtitleChoices[id] = option
                        return TrackOption(id: id, title: option.displayName)
                    }
                }
                item.preferredForwardBufferDuration = 8
                itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.loadID == generation else { return }
                        if item.status == .failed {
                            self.errorMessage = item.error?.localizedDescription ?? NSLocalizedString("Could not read the video.", comment: "")
                            self.cancelPlayback()
                        } else if item.status == .readyToPlay {
                            self.isPreparing = false
                            if !self.isTranscoding {
                                if let group = self.directAudioGroup, let id = self.audioID { item.select(self.directAudioChoices[id], in: group) }
                                if let group = self.directSubtitleGroup { item.select(self.subtitleID.flatMap { self.directSubtitleChoices[$0] }, in: group) }
                                self.player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                                    Task { @MainActor in if self?.loadID == generation, autoPlay { self?.player.play() } }
                                }
                            } else {
                                self.player.seek(to: .zero)
                                if autoPlay { self.player.play() }
                            }
                            self.updateNowPlaying()
                        }
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.finished(generation: generation) }
                }
                failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                    let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                    Task { @MainActor in
                        guard let self, self.loadID == generation else { return }
                        self.errorMessage = reason ?? NSLocalizedString("The video stream was interrupted.", comment: "")
                        self.cancelPlayback()
                    }
                }
                player.replaceCurrentItem(with: item)
                playlist.remember(position: start, duration: duration)
                save()
            } catch is CancellationError {
            } catch {
                guard loadID == generation else { return }
                errorMessage = error.localizedDescription
                cancelPlayback()
            }
        }
    }

    private func finished(generation: UUID) {
        guard loadID == generation else { return }
        playlist.remember(position: 0, duration: duration)
        if let id = playlist.next(finishing: true) {
            // The finished item's saved position is zero before selecting the next one.
            position = 0
            select(id)
        } else {
            cancelPlayback()
            position = duration
            save()
            updateNowPlaying()
        }
    }

    private func cancelPlayback() {
        loadID = UUID()
        preparation?.cancel()
        preparation = nil
        player.pause()
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        player.replaceCurrentItem(with: nil)
        job?.stop()
        job = nil
        server.revokeAll()
        directAudioGroup = nil
        directSubtitleGroup = nil
        directAudioChoices = [:]
        directSubtitleChoices = [:]
        isPreparing = false
        isPlaying = false
        updateActivity()
    }

    private func trackTitle(_ track: MediaTrack) -> String {
        [track.title, track.language?.uppercased(), track.codec.uppercased(), track.channels.map { "\($0) ch" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func remember() { playlist.remember(position: position, duration: duration); save() }
    private func restore() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do { playlist = try JSONDecoder().decode(Playlist.self, from: Data(contentsOf: stateURL)) }
        catch {
            let backup = stateURL.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
            do { try FileManager.default.moveItem(at: stateURL, to: backup) }
            catch { errorMessage = String(format: NSLocalizedString("Could not back up the damaged queue: %@", comment: ""), error.localizedDescription); return }
            errorMessage = String(format: NSLocalizedString("The saved queue is damaged. A backup was kept at %@.", comment: ""), backup.path)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // An interrupted write must leave the previous playlist intact.
            try JSONEncoder().encode(playlist).write(to: stateURL, options: .atomic)
        } catch { errorMessage = String(format: NSLocalizedString("Could not save the queue: %@", comment: ""), error.localizedDescription) }
    }

    private func updateActivity() {
        if isPlaying && activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Playing video via AirPlay") }
        if !isPlaying, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    private func updateNowPlaying() {
        guard let current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.isPlaying == false { self?.togglePlay() } }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.pause(); self?.remember() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
    }

    func shutdown() {
        remember()
        cancelPlayback()
        server.stop()
        routeDetector.isRouteDetectionEnabled = false
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

private struct PlaybackError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
