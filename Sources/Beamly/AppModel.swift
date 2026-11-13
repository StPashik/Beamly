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
    @Published private var playbackControlStatus = AVPlayer.TimeControlStatus.paused
    @Published private var waitingReason: AVPlayer.WaitingReason?
    @Published private(set) var isPreparing = false
    @Published private(set) var preparationStage = PlaybackPreparationStage.readingFile
    @Published private var preparationFraction: Double?
    @Published private(set) var usesSoftwareEncoder = false
    @Published private(set) var usedSoftwareFallback = false
    @Published private var compatibilityReason: String?
    @Published private(set) var isExternal = false
    @Published private(set) var isConnectingAirPlay = false
    @Published private(set) var routesDetected = false
    @Published private(set) var isUsingHLS = false
    @Published private(set) var isVideoCopied = false
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var seekPreviewImage: NSImage?
    @Published private(set) var seekPreviewTime: Double?
    @Published private(set) var isLoadingSeekPreview = false
    @Published private(set) var sleepTimerRemaining: Double?
    @Published private(set) var audioOptions: [TrackOption] = []
    @Published private(set) var subtitleOptions: [TrackOption] = []
    @Published private(set) var audioID: Int?
    @Published private(set) var subtitleID: Int?
    @Published private(set) var externalSubtitle: URL?
    @Published private(set) var externalSubtitleOptions: [URL] = []
    @Published var errorMessage: String?
    @Published var isAirPlayPickerRequested = false

    // Keep one player when changing files so AVKit retains the selected AirPlay route.
    let player: AVPlayer
    private let session = PlaybackSession()
    private let routeDetector = AVRouteDetector()
    private var preparation: Task<Void, Never>?
    private var routePreparation: Task<Void, Never>?
    private var muteBeforeRouteRestart: Bool?
    private var shouldShowAirPlayPicker = false
    private var isAirPlayPickerPresented = false
    private enum AirPlayRouteHint { case none, pickerSelection, confirmed, stopped }
    private var airPlayRouteHint = AirPlayRouteHint.none
    private var previewTask: Task<Void, Never>?
    private var seekPreviewTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private let seekPreviewCache = NSCache<NSNumber, NSImage>()
    private var playRequested = false
    private var loadID = UUID()
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var trackSelectionObserver: NSObjectProtocol?
    // Map the muxer's timestamp shift back to the original movie clock.
    private var sourceOffset = 0.0
    private var lastSavedSecond = -1
    private var lastHistoryItem: PlaylistItem?
    private var activity: NSObjectProtocol?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioChoices: [Int: AVMediaSelectionOption] = [:]
    private var subtitleChoices: [SubtitleChoice: AVMediaSelectionOption] = [:]
    private var preparedSubtitleDelay = 0.0

    private let playlistStore: PlaylistStore
    private let defaults: UserDefaults
    private var tools: FFmpegTools {
        let path = defaults.string(forKey: "toolsDirectory") ?? ""
        return FFmpegTools(customDirectory: path.isEmpty ? nil : URL(fileURLWithPath: path))
    }

    init(stateURL: URL? = nil, defaults: UserDefaults = .standard, player: AVPlayer = AVPlayer()) {
        self.player = player
        playlistStore = PlaylistStore(url: stateURL)
        self.defaults = defaults
        seekPreviewCache.countLimit = 16
        seekPreviewCache.totalCostLimit = 4 * 1024 * 1024
        defaults.register(defaults: ["autoPlay": true, "directPlayback": true, "hardwareEncoding": true, "appearance": "system", "preferredAudioLanguage": "default", "preferredSubtitleLanguage": "automatic"])
        restore()
        duration = playlist.current?.duration ?? 0
        position = playlist.current?.position ?? 0
        lastHistoryItem = playlist.current
        player.allowsExternalPlayback = true
        routeDetector.isRouteDetectionEnabled = true
        observations = [
            player.observe(\.isExternalPlaybackActive, options: [.initial, .old, .new]) { [weak self] player, change in
                let lostRoute = change.oldValue == true && change.newValue == false
                if lostRoute, !player.isExternalPlaybackActive, player.timeControlStatus != .paused { player.pause() }
                Task { @MainActor in
                    guard let self else { return }
                    self.isExternal = player.isExternalPlaybackActive
                    if self.isExternal {
                        // The previous item can still report route activity after Clear.
                        if self.airPlayRouteHint != .stopped { self.airPlayRouteHint = .confirmed }
                        self.isAirPlayPickerRequested = false
                        if self.playRequested, !self.isPreparing { self.playIfConnected() }
                    } else if lostRoute, player.currentItem != nil, !self.isPreparing, !self.isConnectingAirPlay {
                        if self.playRequested { self.airPlayRouteHint = .none }
                        self.pausePlayback()
                    }
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                if !player.isExternalPlaybackActive, !player.isMuted, player.timeControlStatus != .paused { player.pause() }
                Task { @MainActor in
                    guard let self else { return }
                    if (self.current == nil || self.isPreparing || (!player.isExternalPlaybackActive && self.muteBeforeRouteRestart == nil)),
                       player.timeControlStatus != .paused { player.pause() }
                    self.refreshPlaybackState()
                }
            },
            player.observe(\.reasonForWaitingToPlay, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshPlaybackState() }
            },
            routeDetector.observe(\.multipleRoutesDetected, options: [.initial, .new]) { [weak self] detector, _ in
                Task { @MainActor in self?.routesDetected = detector.multipleRoutesDetected }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPreparing, self.muteBeforeRouteRestart == nil,
                      self.player.currentItem != nil, self.player.isExternalPlaybackActive else { return }
                let seconds = self.player.currentTime().seconds
                guard seconds.isFinite else { return }
                if self.isExternal { self.refreshTrackChoices() }
                self.position = min(self.duration, max(0, self.sourceOffset + seconds))
                self.playlist.remember(position: self.position, duration: self.duration)
                let second = Int(self.position)
                if second % 5 == 0 && second != self.lastSavedSecond {
                    self.lastSavedSecond = second
                    if self.isPlaying { self.rememberHistory() }
                    self.save()
                    self.updateNowPlaying()
                }
            }
        }
        configureRemoteCommands()
        loadPreview()
    }

    // MARK: - Queue and playback state

    var current: PlaylistItem? { playlist.current }
    var sleepTimerDescription: String? {
        sleepTimerRemaining.map { String(format: NSLocalizedString("Stop playback in %@", comment: ""), mediaTime(ceil($0))) }
    }
    var chapters: [MediaChapter] { info?.chapters ?? [] }

    func chapter(at seconds: Double) -> MediaChapter? {
        guard seconds.isFinite else { return nil }
        return chapters.last { $0.start <= seconds && seconds < $0.end }
    }
    func chapterTitle(_ chapter: MediaChapter) -> String {
        chapter.title ?? String(format: NSLocalizedString("Chapter %d", comment: ""), (chapters.firstIndex { $0.id == chapter.id } ?? 0) + 1)
    }
    func seekChapter(_ id: Int) {
        guard !isPreparing, let chapter = chapters.first(where: { $0.id == id }) else { return }
        seek(chapter.start)
    }
    var subtitleDelay: Double { current?.subtitleDelay ?? 0 }
    var audioDelay: Double { current?.audioDelay ?? 0 }
    var watchHistory: [WatchHistoryEntry] { playlist.history ?? [] }

    func resumeHistory(_ url: URL) {
        remember()
        guard let saved = watchHistory.first(where: { $0.id == url }),
              url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            errorMessage = String(format: NSLocalizedString("File not found or inaccessible: %@", comment: ""), url.lastPathComponent)
            return
        }
        let wasEmpty = playlist.items.isEmpty
        playlist.append([url])
        if wasEmpty {
            position = playlist.current?.position ?? 0
            duration = playlist.current?.duration ?? 0
        }
        guard let index = playlist.items.firstIndex(where: { $0.url == url }) else { return }
        select(playlist.items[index].id, resumeAt: saved.video.position)
    }

    func removeHistory(_ url: URL) {
        if current?.url == url { lastHistoryItem = current }
        playlist.history?.removeAll { $0.id == url }
        save()
    }
    func clearHistory() { lastHistoryItem = current; playlist.history = []; save() }
    // Leave Play available while a dismissed picker has yet to yield a confirmed receiver.
    var isPlaying: Bool {
        playbackControlStatus != .paused || (isConnectingAirPlay && (airPlayRouteHint == .confirmed || airPlayRouteHint == .stopped))
    }
    var isBuffering: Bool {
        !isPreparing && isExternal && player.currentItem != nil &&
            playbackControlStatus == .waitingToPlayAtSpecifiedRate && waitingReason == .toMinimizeStalls
    }
    var playbackStatus: String {
        if isPreparing {
            let stage = NSLocalizedString(preparationStage.rawValue, comment: "")
            return preparationFraction.map { "\(stage) \($0.formatted(.percent.precision(.fractionLength(0))))" } ?? stage
        }
        guard player.currentItem != nil else { return errorMessage ?? NSLocalizedString("Ready to play", comment: "") }
        if isConnectingAirPlay { return NSLocalizedString("Starting playback…", comment: "") }
        if !isExternal { return NSLocalizedString("Choose an AirPlay device to start playback.", comment: "") }
        if isBuffering { return NSLocalizedString("Buffering…", comment: "") }
        if playbackControlStatus == .waitingToPlayAtSpecifiedRate { return NSLocalizedString("Starting playback…", comment: "") }
        return isPlaying ? NSLocalizedString("Playing via AirPlay", comment: "") : NSLocalizedString("Paused", comment: "")
    }
    var qualityTitle: String? {
        guard isPreparing ? preparationStage != .readingFile : player.currentItem != nil else { return nil }
        return isUsingHLS && !isVideoCopied
            ? NSLocalizedString("Compatibility conversion · up to 1080p SDR", comment: "")
            : NSLocalizedString("Original video quality", comment: "")
    }
    var qualityExplanation: String? {
        guard !isPreparing, qualityTitle != nil else { return nil }
        if isVideoCopied { return NSLocalizedString("Prepared for AirPlay without video conversion.", comment: "") }
        if !isUsingHLS { return NSLocalizedString("Direct playback without video conversion.", comment: "") }
        var reasons = [compatibilityReason].compactMap { $0 }
        if usedSoftwareFallback { reasons.insert(NSLocalizedString("System conversion failed; using the software encoder.", comment: ""), at: 0) }
        else if usesSoftwareEncoder { reasons.append(NSLocalizedString("Software encoding is in use.", comment: "")) }
        return reasons.joined(separator: " ")
    }
    var status: String {
        if isPreparing || isConnectingAirPlay || (isExternal && player.currentItem != nil) { return playbackStatus }
        if isExternal { return NSLocalizedString("AirPlay connected", comment: "") }
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
                var result: [URL] = []
                for url in urls where url.isFileURL {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                        while let child = iterator?.nextObject() as? URL {
                            if videoFileExtensions.contains(child.pathExtension.lowercased()), (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.append(child) }
                        }
                    } else if videoFileExtensions.contains(url.pathExtension.lowercased()) {
                        result.append(url)
                    }
                }
                return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }.value
            let wasEmpty = playlist.items.isEmpty
            playlist.append(videos)
            if wasEmpty {
                position = playlist.current?.position ?? 0
                duration = playlist.current?.duration ?? 0
            }
            save()
            if wasEmpty, let id = playlist.currentID { select(id, autoPlay: defaults.bool(forKey: "autoPlay")) }
            if videos.isEmpty, let subtitle = urls.first(where: { ["srt", "ass", "ssa", "vtt"].contains($0.pathExtension.lowercased()) }) {
                attachSubtitle(subtitle)
            } else if videos.isEmpty { errorMessage = NSLocalizedString("The selected files contain no supported videos.", comment: "") }
        }
    }

    func select(_ id: UUID, autoPlay: Bool = true, resumeAt: Double? = nil) {
        guard playlist.items.contains(where: { $0.id == id }) else { return }
        remember()
        playlist.currentID = id
        info = nil
        audioID = nil
        subtitleID = nil
        externalSubtitle = nil
        externalSubtitleOptions = []
        audioOptions = []
        subtitleOptions = []
        position = resumeAt ?? playlist.current?.position ?? 0
        duration = playlist.current?.duration ?? 0
        loadPreview()
        save()
        prepare(at: duration > 0 && position > duration - 3 ? 0 : position, autoPlay: autoPlay, applyTrackPreferences: true)
    }

    // MARK: - AirPlay and playback controls

    func togglePlay() {
        if isPreparing {
            setSleepTimer(nil)
            remember()
            cancelPlayback()
            updateNowPlaying()
            return
        }
        if player.currentItem == nil {
            if let id = playlist.currentID {
                select(id)
                playIfConnected(showPicker: true)
            } else { openFiles() }
        } else if isPlaying || (playRequested && (isAirPlayPickerRequested || isAirPlayPickerPresented)) {
            pausePlayback()
        } else {
            if player.isExternalPlaybackActive, duration > 0 && position >= duration - 0.5 { seek(0) }
            playIfConnected(showPicker: true)
        }
    }

    func airPlayPickerPresentationChanged(_ isPresented: Bool) {
        guard isAirPlayPickerPresented != isPresented else { return }
        isAirPlayPickerPresented = isPresented
        if isPresented {
            // AVKit reports presentation without saying whether the user selected a route.
            airPlayRouteHint = .pickerSelection
            shouldShowAirPlayPicker = false
            if routePreparation != nil { cancelRoutePreparation() }
        } else if playRequested {
            playIfConnected()
        }
    }

    private func requestAirPlayPicker() {
        guard shouldShowAirPlayPicker else { return }
        shouldShowAirPlayPicker = false
        if !isAirPlayPickerPresented { isAirPlayPickerRequested = true }
    }

    private func playIfConnected(showPicker: Bool = false) {
        playRequested = true
        shouldShowAirPlayPicker = shouldShowAirPlayPicker || showPicker
        if !player.isExternalPlaybackActive {
            if showPicker, !isAirPlayPickerPresented, airPlayRouteHint == .pickerSelection {
                cancelRoutePreparation()
                airPlayRouteHint = .none
            }
            if airPlayRouteHint == .none || isAirPlayPickerPresented { requestAirPlayPicker() }
        }
        guard !isPreparing, player.status == .readyToPlay, player.currentItem?.status == .readyToPlay else { return }
        guard player.isExternalPlaybackActive else {
            guard airPlayRouteHint != .none, !isAirPlayPickerPresented, routePreparation == nil else { return }
            isConnectingAirPlay = true
            let generation = loadID
            routePreparation = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                guard let self, self.loadID == generation, self.playRequested else { return }
                if self.player.isExternalPlaybackActive { self.playIfConnected() }
                else {
                    self.cancelRoutePreparation()
                    self.airPlayRouteHint = .none
                    self.requestAirPlayPicker()
                }
            }
            if airPlayRouteHint == .stopped {
                // shortcut: AVPlayer needs a muted start after Clear, use a route reactivation API if AVKit adds one.
                shouldShowAirPlayPicker = true
                muteBeforeRouteRestart = player.isMuted
                player.isMuted = true
                player.play()
            } else {
                player.preroll(atRate: 1, completionHandler: nil)
            }
            return
        }
        cancelRoutePreparation()
        airPlayRouteHint = .confirmed
        isAirPlayPickerRequested = false
        shouldShowAirPlayPicker = false
        player.play()
        refreshPlaybackState()
    }

    private func cancelRoutePreparation() {
        routePreparation?.cancel()
        routePreparation = nil
        player.cancelPendingPrerolls()
        if let muteBeforeRouteRestart {
            if !player.isExternalPlaybackActive {
                player.pause()
                let target = CMTime(seconds: max(0, position - sourceOffset), preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            self.muteBeforeRouteRestart = nil
            player.isMuted = muteBeforeRouteRestart
        }
        isConnectingAirPlay = false
    }

    private func pausePlayback() {
        cancelRoutePreparation()
        isAirPlayPickerRequested = false
        shouldShowAirPlayPicker = false
        playRequested = false
        player.pause()
        refreshPlaybackState()
        remember()
    }

    private func refreshPlaybackState() {
        playbackControlStatus = muteBeforeRouteRestart == nil ? player.timeControlStatus : .paused
        waitingReason = player.reasonForWaitingToPlay
        updateActivity()
        updateNowPlaying()
    }

    func stop() {
        setSleepTimer(nil)
        remember()
        cancelPlayback()
        position = 0
        playlist.remember(position: 0, duration: duration)
        lastHistoryItem = current
        save()
        updateNowPlaying()
    }

    func setSleepTimer(_ seconds: Double?) {
        if let seconds {
            guard current != nil, seconds.isFinite, seconds > 0, seconds <= 2 * 60 * 60 else { return }
        }
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemaining = seconds
        guard let seconds else { return }
        // Continuous time includes system suspension and ignores wall-clock adjustments.
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        sleepTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                let interval = ContinuousClock.now.duration(to: deadline).components
                let remaining = Double(interval.seconds) + Double(interval.attoseconds) / 1e18
                if remaining <= 0 {
                    guard let self else { return }
                    self.sleepTimerTask = nil
                    self.sleepTimerRemaining = nil
                    self.remember()
                    self.cancelPlayback()
                    self.updateNowPlaying()
                    return
                }
                self?.sleepTimerRemaining = remaining
                do { try await Task.sleep(for: .seconds(min(1, remaining)), clock: .continuous) }
                catch { return }
            }
        }
    }

    func next() { if let id = playlist.next() { select(id) } }
    func previous() {
        if position > 3 { seek(0) }
        else if let id = playlist.previous() { select(id) }
    }

    func seek(_ seconds: Double) {
        guard !isPreparing, seconds.isFinite, duration > 0 else { return }
        let target = min(max(0, seconds), max(0, duration - 0.05))
        position = target
        player.seek(to: CMTime(seconds: max(0, target - sourceOffset), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        remember()
        updateNowPlaying()
    }

    // MARK: - Audio and subtitles

    func setAudio(_ id: Int?) {
        audioID = id
        if !isPreparing, let item = player.currentItem, selectAudio(id, in: item) { return }
        prepare(at: position, autoPlay: isPlaying || playRequested)
    }

    private func selectAudio(_ id: Int?, in item: AVPlayerItem) -> Bool {
        guard let group = audioGroup else { return false }
        if isUsingHLS {
            guard let trackID = id ?? info?.defaultAudioTrack?.id, let option = audioChoices[trackID] else { return false }
            item.select(option, in: group)
        } else if let id {
            item.select(audioChoices[id], in: group)
        } else if let option = group.defaultOption {
            item.select(option, in: group)
        } else {
            item.selectMediaOptionAutomatically(in: group)
        }
        return true
    }

    func setSubtitle(_ id: Int?) {
        selectSubtitle(id.map(SubtitleChoice.embedded) ?? .none)
    }

    private var subtitleChoice: SubtitleChoice {
        externalSubtitle.map(SubtitleChoice.external) ?? subtitleID.map(SubtitleChoice.embedded) ?? .none
    }

    private func updateSubtitleChoice(_ choice: SubtitleChoice) {
        guard choice != subtitleChoice else { return }
        if case .embedded(let id) = choice { subtitleID = id } else { subtitleID = nil }
        if case .external(let url) = choice { externalSubtitle = url } else { externalSubtitle = nil }
    }

    private func refreshTrackChoices() {
        guard let item = player.currentItem else { return }
        if let group = audioGroup,
           let option = item.currentMediaSelection.selectedMediaOption(in: group),
           let id = audioChoices.first(where: { $0.value == option })?.key {
            let nativeDefault = isUsingHLS ? nil : group.defaultOption.flatMap { option in
                audioChoices.first(where: { $0.value == option })?.key
            }
            let defaultID = nativeDefault ?? info?.defaultAudioTrack?.id
            // Keep the Default menu choice until the receiver actually switches tracks.
            if id != (audioID ?? defaultID) { audioID = id }
        }
        guard let group = subtitleGroup else { return }
        guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else {
            updateSubtitleChoice(.none)
            return
        }
        if let choice = subtitleChoices.first(where: { $0.value == option })?.key { updateSubtitleChoice(choice) }
    }

    private func selectSubtitle(_ choice: SubtitleChoice) {
        updateSubtitleChoice(choice)
        let option = subtitleChoices[choice]
        if !isPreparing, let group = subtitleGroup,
           choice == .none || (option != nil && subtitleDelay == preparedSubtitleDelay) {
            player.currentItem?.select(option, in: group)
        } else { prepare(at: position, autoPlay: isPlaying || playRequested) }
    }

    func setSubtitleDelay(_ seconds: Double) {
        guard seconds.isFinite, seconds != subtitleDelay,
              let index = playlist.items.firstIndex(where: { $0.id == playlist.currentID }) else { return }
        playlist.items[index].subtitleDelay = seconds == 0 ? nil : seconds
        save()
        if subtitleID != nil || externalSubtitle != nil { prepare(at: position, autoPlay: isPlaying || playRequested) }
    }

    func setAudioDelay(_ seconds: Double) {
        guard seconds.isFinite, abs(seconds) <= 10 else { return }
        // Quantize to the UI step so floating-point residue cannot leave a hidden correction.
        let correction = (seconds * 10).rounded() / 10
        guard correction != audioDelay,
              let index = playlist.items.firstIndex(where: { $0.id == playlist.currentID }) else { return }
        playlist.items[index].audioDelay = correction == 0 ? nil : correction
        remember()
        if player.currentItem != nil || isPreparing { prepare(at: position, autoPlay: isPlaying || playRequested) }
    }

    func chooseSubtitle() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose subtitles", comment: "")
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { attachSubtitle(url) }
    }

    func attachSubtitle(_ url: URL) {
        guard current != nil else { errorMessage = NSLocalizedString("Add a video first.", comment: ""); return }
        let file = externalSubtitleOptions.first { $0.standardizedFileURL == url.standardizedFileURL } ?? url
        selectSubtitle(.external(file))
    }

    // MARK: - Queue changes

    func remove(_ id: UUID) {
        // Removing a queue entry never removes the movie from disk.
        let active = id == playlist.currentID
        if active { remember(); cancelPlayback() }
        playlist.remove(id)
        if playlist.items.isEmpty { setSleepTimer(nil) }
        save()
        if active {
            position = playlist.current?.position ?? 0
            duration = playlist.current?.duration ?? 0
            if let next = playlist.currentID { select(next, autoPlay: false) }
            else {
                info = nil; position = 0; duration = 0
                subtitleID = nil; externalSubtitle = nil; externalSubtitleOptions = []
                loadPreview()
            }
        }
    }

    func clear() {
        setSleepTimer(nil)
        remember()
        if player.currentItem != nil, player.isExternalPlaybackActive || airPlayRouteHint == .confirmed {
            airPlayRouteHint = .stopped
        }
        cancelPlayback()
        playlist.items.removeAll()
        playlist.currentID = nil
        subtitleID = nil
        externalSubtitle = nil
        externalSubtitleOptions = []
        loadPreview()
        info = nil
        duration = 0
        position = 0
        save()
        updateNowPlaying()
    }

    func move(from offsets: IndexSet, to destination: Int) { playlist.items.move(fromOffsets: offsets, toOffset: destination); save() }
    func toggleShuffle() { playlist.shuffle.toggle(); save() }
    func setRepeat(_ mode: RepeatMode) { playlist.repeatMode = mode; save() }

    // MARK: - Preview frames

    private func loadPreview() {
        previewTask?.cancel()
        requestSeekPreview(nil)
        seekPreviewCache.removeAllObjects()
        previewImage = nil
        guard let movie = current else { return }
        let tools = tools
        previewTask = Task { [weak self] in
            let asset = AVURLAsset(url: movie.url)
            let duration: Double
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 { duration = seconds }
            else {
                guard !Task.isCancelled else { return }
                duration = (try? await tools.probe(url: movie.url))?.duration ?? 0
            }
            guard !Task.isCancelled else { return }
            let middle = duration.isFinite && duration > 0 ? duration / 2 : 0
            let image = await PlaybackMedia.thumbnail(url: movie.url, at: middle, tools: tools)
            guard !Task.isCancelled, self?.current?.id == movie.id else { return }
            self?.previewImage = image
        }
    }

    func requestSeekPreview(_ seconds: Double?) {
        guard let seconds, seconds.isFinite, seconds >= 0, duration.isFinite, duration > 0,
              !isPreparing, let movie = current else {
            seekPreviewTask?.cancel()
            seekPreviewTask = nil
            seekPreviewTime = nil
            seekPreviewImage = nil
            isLoadingSeekPreview = false
            return
        }
        // One source frame per second avoids decoding on every pointer movement.
        let target = min(floor(seconds), max(0, duration - 0.05))
        guard seekPreviewTime != target else { return }
        seekPreviewTask?.cancel()
        seekPreviewTask = nil
        seekPreviewTime = target
        seekPreviewImage = seekPreviewCache.object(forKey: NSNumber(value: target))
        isLoadingSeekPreview = seekPreviewImage == nil
        guard isLoadingSeekPreview else { return }
        let tools = tools
        seekPreviewTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            let image = await PlaybackMedia.thumbnail(url: movie.url, at: target, tools: tools)
            guard !Task.isCancelled, let self, self.current?.id == movie.id, self.seekPreviewTime == target else { return }
            if let image { self.seekPreviewCache.setObject(image, forKey: NSNumber(value: target), cost: 288 * 162 * 4) }
            self.seekPreviewImage = image
            self.isLoadingSeekPreview = false
        }
    }

    // MARK: - Item preparation and handoff

    private func prepare(at start: Double, autoPlay: Bool, applyTrackPreferences: Bool = false, retrying: PlaybackRetry? = nil) {
        guard let movie = current else { return }
        let showPicker = shouldShowAirPlayPicker
        cancelPlayback(keepingItem: true)
        // Cancellation is cooperative; this ID also rejects callbacks from an older load.
        let generation = loadID
        let start = max(0, start)
        isPreparing = true
        preparationStage = .readingFile
        playRequested = autoPlay
        shouldShowAirPlayPicker = autoPlay && showPicker
        position = start
        let preferences = TrackPreferences(audio: defaults.string(forKey: "preferredAudioLanguage") ?? "default",
                                           subtitles: defaults.string(forKey: "preferredSubtitleLanguage") ?? "automatic")
        let preserveQuality = defaults.bool(forKey: "directPlayback")
        let hardwareEncoding = defaults.bool(forKey: "hardwareEncoding")
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                guard FileManager.default.isReadableFile(atPath: movie.url.path) else {
                    throw PlaybackError(String(format: NSLocalizedString("File not found or inaccessible: %@", comment: ""), movie.url.lastPathComponent))
                }
                if applyTrackPreferences {
                    let files = await Task.detached(priority: .userInitiated) { findSubtitleFiles(for: movie.url) }.value
                    try Task.checkCancellation()
                    guard loadID == generation else { return }
                    externalSubtitleOptions = files
                }
                let asset = AVURLAsset(url: movie.url)
                let metadata = try await PlaybackMedia.metadata(for: movie.url, asset: asset, tools: tools)
                try Task.checkCancellation()
                guard loadID == generation else { return }
                info = metadata
                duration = metadata.duration.isFinite ? max(0, metadata.duration) : 0
                // Rebuilds retain manual choices; preferences apply only when opening a video.
                if applyTrackPreferences {
                    applyInitialTrackPreferences(preferences, metadata: metadata, preserveQuality: preserveQuality, url: movie.url)
                }
                var canPlayDirect = false
                if retrying == nil, PlaybackMedia.isNativeContainer(movie.url), externalSubtitle == nil,
                   subtitleID == nil || subtitleDelay == 0, audioDelay == 0, preserveQuality {
                    canPlayDirect = (try? await asset.load(.isPlayable)) == true
                }
                try Task.checkCancellation()
                try await session.server.start()
                try Task.checkCancellation()
                let captionDelay = subtitleDelay
                let playbackURL: URL
                let retry: PlaybackRetry?
                if canPlayDirect {
                    retry = .hls
                    isUsingHLS = false
                    isVideoCopied = false
                    sourceOffset = 0
                    playbackURL = try session.server.publish(file: movie.url)
                } else {
                    guard let stream = try await publishPreparedStream(input: movie.url, metadata: metadata, start: start,
                        generation: generation, captionDelay: captionDelay, preserveQuality: preserveQuality,
                        hardwareEncoding: hardwareEncoding, retrying: retrying) else { return }
                    (playbackURL, retry) = stream
                }
                try Task.checkCancellation()
                guard loadID == generation else { return }
                preparationFraction = nil
                preparationStage = .loadingPlayer
                let item = AVPlayerItem(url: playbackURL)
                if isUsingHLS {
                    guard try await loadHLSTracks(for: item, captionDelay: captionDelay, generation: generation) else { return }
                }
                if canPlayDirect {
                    let trackPreferences = applyTrackPreferences ? preferences : nil
                    guard try await loadNativeTracks(for: item, input: movie.url, metadata: metadata,
                                                    preferences: trackPreferences, start: start, generation: generation) else { return }
                }
                installPlayerItem(item, start: start, generation: generation, retry: retry)
            } catch is CancellationError {
            } catch where MediaPipelineError.isInsufficientSpace(error) {
                playbackFailed(MediaPipelineError.insufficientSpace.localizedDescription, generation: generation, retry: nil)
            } catch {
                let retry: PlaybackRetry?
                if session.job?.pendingHLSFiles.isEmpty == false { retry = .completeHLS }
                else { retry = session.job?.usesOriginalDolby == true ? .stereo : nil }
                playbackFailed(error.localizedDescription, generation: generation, retry: retry)
            }
        }
    }

    private func applyInitialTrackPreferences(_ preferences: TrackPreferences, metadata: MediaInfo, preserveQuality: Bool, url: URL) {
        audioID = preferences.audioTrack(in: metadata.audioTracks)
        let captions = metadata.subtitleTracks.filter { $0.isTextSubtitle || (!preserveQuality && $0.isBitmapSubtitle) }
        switch preferences.subtitleChoice(in: captions, files: externalSubtitleOptions, video: url) {
        case .none: subtitleID = nil; externalSubtitle = nil
        case .embedded(let id): subtitleID = id; externalSubtitle = nil
        case .external(let url): subtitleID = nil; externalSubtitle = url
        }
    }

    private func publishPreparedStream(input: URL, metadata: MediaInfo, start: Double, generation: UUID, captionDelay: Double,
                                       preserveQuality: Bool, hardwareEncoding: Bool,
                                       retrying: PlaybackRetry?) async throws -> (url: URL, retry: PlaybackRetry?)? {
        let playbackURL: URL
        let retry: PlaybackRetry?
        isUsingHLS = true
        audioOptions = metadata.audioTracks.map { TrackOption(id: $0.id, title: PlaybackMedia.title(for: $0)) }
        subtitleOptions = metadata.subtitleTracks.map { TrackOption(id: $0.id, title: PlaybackMedia.title(for: $0)) }
        let newJob = HLSJob(tools: tools)
        session.job = newJob
        compatibilityReason = NSLocalizedString(preserveQuality ? "This video format requires compatibility conversion." : "Preserve video quality is off.", comment: "")
        let choice = subtitleChoice
        let reportFraction: @MainActor (Double) -> Void = { [weak self] fraction in
            guard let self, self.loadID == generation else { return }
            self.preparationFraction = max(self.preparationFraction ?? 0, fraction)
        }
        let reportStage: @MainActor (PlaybackPreparationStage) -> Void = { [weak self] stage in
            guard let self, self.loadID == generation else { return }
            self.preparationFraction = nil
            self.preparationStage = stage
            switch stage {
            case .originalStream: self.isVideoCopied = true
            case .systemEncoding: self.isVideoCopied = false; self.usesSoftwareEncoder = false
            case .softwareEncoding: self.isVideoCopied = false; self.usesSoftwareEncoder = true
            case .softwareFallback: self.usedSoftwareFallback = true
            default: break
            }
        }
        let earlyPlaylist: URL?
        if retrying == nil || retrying == .hls, preserveQuality, audioDelay == 0 {
            earlyPlaylist = try await newJob.prepareEarlyHLS(input: input, info: metadata, audioTrack: audioID,
                startTime: start, subtitle: choice, subtitleDelay: captionDelay, onFailure: { [weak self] error in
                    if MediaPipelineError.isInsufficientSpace(error) {
                        self?.playbackFailed(MediaPipelineError.insufficientSpace.localizedDescription, generation: generation, retry: nil)
                    } else {
                        self?.playbackFailed(error.localizedDescription, generation: generation, retry: .completeHLS)
                    }
                }, progress: reportStage)
        } else {
            earlyPlaylist = nil
        }
        if let earlyPlaylist {
            try Task.checkCancellation()
            guard loadID == generation else { return nil }
            duration = newJob.earlyHLSVideoDuration ?? duration
            retry = .completeHLS
            playbackURL = try session.server.publish(directory: earlyPlaylist.deletingLastPathComponent(),
                playlist: earlyPlaylist.lastPathComponent, pendingFiles: newJob.pendingHLSFiles,
                generatedDirectory: newJob.generatedHLSSegments, onPendingRequest: { [weak newJob] name in
                    Task { @MainActor in newJob?.requestPendingHLSFile(name) }
                }, onPendingTimeout: { [weak self] in
                    Task { @MainActor in self?.playbackFailed(generation: generation, retry: .completeHLS) }
                })
        } else if retrying == nil, preserveQuality, choice == .none, audioDelay == 0,
                  let mp4 = try await newJob.prepareNativeMP4(input: input, info: metadata, audioTrack: audioID,
                                                            onFraction: reportFraction, progress: reportStage) {
            try Task.checkCancellation()
            guard loadID == generation else { return nil }
            retry = .hls
            isUsingHLS = false
            playbackURL = try session.server.publish(file: mp4)
        } else {
            let playlist = try await newJob.start(input: input, info: metadata, audioTrack: audioID, subtitle: choice,
                hardwareEncoding: hardwareEncoding, preserveQuality: preserveQuality, subtitleDelay: captionDelay, audioDelay: audioDelay,
                allowDolbyAudio: retrying != .stereo, onFraction: reportFraction, progress: reportStage)
            try Task.checkCancellation()
            guard loadID == generation else { return nil }
            retry = newJob.usesOriginalDolby ? .stereo : nil
            playbackURL = try session.server.publish(directory: playlist.deletingLastPathComponent(), playlist: playlist.lastPathComponent)
        }
        sourceOffset = newJob.sourceOffset
        isVideoCopied = newJob.isVideoCopied
        return (playbackURL, retry)
    }

    private func loadHLSTracks(for item: AVPlayerItem, captionDelay: Double, generation: UUID) async throws -> Bool {
        if let audioNames = session.job?.audioNames, !audioNames.isEmpty {
            let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
            let options = await PlaybackMedia.hlsTrackOptions(in: group, names: audioNames)
            try Task.checkCancellation()
            guard loadID == generation else { return false }
            audioGroup = group
            audioChoices = options
        }
        if let subtitleNames = session.job?.subtitleNames, !subtitleNames.isEmpty {
            let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
            let options = await PlaybackMedia.hlsTrackOptions(in: group, names: subtitleNames)
            try Task.checkCancellation()
            guard loadID == generation else { return false }
            subtitleGroup = group
            preparedSubtitleDelay = captionDelay
            subtitleChoices = options
        }
        return true
    }

    private func loadNativeTracks(for item: AVPlayerItem, input: URL, metadata: MediaInfo,
                                  preferences: TrackPreferences?, start: Double, generation: UUID) async throws -> Bool {
        // Select tracks from the streamed asset, whose groups belong to this player item.
        let audioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        let subtitleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        try Task.checkCancellation()
        guard loadID == generation else { return false }
        self.audioGroup = audioGroup
        self.subtitleGroup = subtitleGroup
        let audioTracks = PlaybackMedia.nativeTracks(in: audioGroup, source: metadata.audioTracks, choices: &audioChoices)
        var nativeSubtitleChoices: [Int: AVMediaSelectionOption] = [:]
        let subtitleTracks = PlaybackMedia.nativeTracks(in: subtitleGroup, source: metadata.subtitleTracks, choices: &nativeSubtitleChoices)
        subtitleChoices = Dictionary(uniqueKeysWithValues: nativeSubtitleChoices.map { (SubtitleChoice.embedded($0.key), $0.value) })
        audioOptions = audioTracks.map { TrackOption(id: $0.id, title: $0.title ?? "") }
        subtitleOptions = subtitleTracks.map { TrackOption(id: $0.id, title: $0.title ?? "") }
        if let preferences {
            audioID = preferences.audioTrack(in: audioTracks)
            if case .embedded(let id) = preferences.subtitleChoice(in: subtitleTracks, files: [], video: input) { subtitleID = id }
            else { subtitleID = nil }
            if subtitleID != nil, subtitleDelay != 0 {
                prepare(at: start, autoPlay: playRequested)
                return false
            }
        }
        return true
    }

    private func installPlayerItem(_ item: AVPlayerItem, start: Double, generation: UUID, retry: PlaybackRetry?) {
        item.preferredForwardBufferDuration = 8
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.loadID == generation else { return }
                if item.status == .failed {
                    let reason = item.error?.localizedDescription ?? NSLocalizedString("Could not read the video.", comment: "")
                    self.playbackFailed(reason, generation: generation, retry: retry)
                } else if item.status == .readyToPlay {
                    _ = self.selectAudio(self.audioID, in: item)
                    if let group = self.subtitleGroup { item.select(self.subtitleChoices[self.subtitleChoice], in: group) }
                    // Ignore time-zero callbacks until the saved position has been restored.
                    let target = CMTime(seconds: max(0, start - self.sourceOffset), preferredTimescale: 600)
                    self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                        Task { @MainActor in
                            guard let self, self.loadID == generation else { return }
                            if !completed, retry == .completeHLS || retry == .hls {
                                self.playbackFailed(generation: generation, retry: retry)
                                return
                            }
                            self.session.releasePrevious()
                            self.isPreparing = false
                            if self.playRequested { self.playIfConnected() }
                            self.updateNowPlaying()
                        }
                    }
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finished(generation: generation) }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                self?.playbackFailed(reason ?? NSLocalizedString("The video stream was interrupted.", comment: ""),
                                     generation: generation, retry: retry)
            }
        }
        if audioGroup != nil || subtitleGroup != nil {
            trackSelectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.loadID == generation, !self.isPreparing else { return }
                    self.refreshTrackChoices()
                }
            }
        }
        player.replaceCurrentItem(with: item)
        playlist.remember(position: start, duration: duration)
        save()
    }

    private enum PlaybackRetry {
        case hls, completeHLS, stereo
    }

    private func playbackFailed(_ reason: String? = nil, generation: UUID, retry: PlaybackRetry?) {
        guard loadID == generation else { return }
        if let retry {
            prepare(at: position, autoPlay: playRequested, retrying: retry)
        } else {
            errorMessage = reason ?? NSLocalizedString("The video stream was interrupted.", comment: "")
            cancelPlayback()
        }
    }

    private func finished(generation: UUID) {
        guard loadID == generation, muteBeforeRouteRestart == nil else { return }
        playlist.remember(position: duration, duration: duration)
        rememberHistory()
        playlist.remember(position: 0, duration: duration)
        if let id = playlist.next(finishing: true) {
            // The finished item's saved position is zero before selecting the next one.
            position = 0
            lastHistoryItem = current
            select(id)
        } else {
            cancelPlayback()
            position = duration
            save()
            updateNowPlaying()
        }
    }

    private func cancelPlayback(keepingItem: Bool = false) {
        requestSeekPreview(nil)
        cancelRoutePreparation()
        isAirPlayPickerRequested = false
        shouldShowAirPlayPicker = false
        playRequested = false
        loadID = UUID()
        preparation?.cancel()
        preparation = nil
        player.pause()
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let trackSelectionObserver { NotificationCenter.default.removeObserver(trackSelectionObserver) }
        endObserver = nil
        failureObserver = nil
        trackSelectionObserver = nil
        session.cancel(player: player, keepingItem: keepingItem)
        audioGroup = nil
        subtitleGroup = nil
        audioChoices = [:]
        subtitleChoices = [:]
        preparedSubtitleDelay = 0
        isPreparing = false
        preparationFraction = nil
        preparationStage = .readingFile
        playbackControlStatus = .paused
        waitingReason = nil
        usesSoftwareEncoder = false
        usedSoftwareFallback = false
        compatibilityReason = nil
        isVideoCopied = false
        updateActivity()
    }

    // MARK: - Persistence

    private func remember() {
        playlist.remember(position: position, duration: duration)
        rememberHistory()
        save()
    }
    private func rememberHistory() {
        guard let current, current != lastHistoryItem else { return }
        playlist.recordHistory(current)
        lastHistoryItem = current
    }
    private func restore() {
        do {
            if let saved = try playlistStore.load() { playlist = saved }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do { try playlistStore.save(playlist) }
        catch { errorMessage = String(format: NSLocalizedString("Could not save the queue: %@", comment: ""), error.localizedDescription) }
    }

    // MARK: - System playback integration

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
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pausePlayback() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
    }

    func shutdown() {
        setSleepTimer(nil)
        previewTask?.cancel()
        seekPreviewCache.removeAllObjects()
        remember()
        cancelPlayback()
        session.server.stop()
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
