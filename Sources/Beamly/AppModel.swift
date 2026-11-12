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
    private var server = MediaHTTPServer()
    private var previousPlayback: (item: AVPlayerItem, server: MediaHTTPServer, job: HLSJob?)?
    private let routeDetector = AVRouteDetector()
    private var job: HLSJob?
    private var preparation: Task<Void, Never>?
    private var routePreparation: Task<Void, Never>?
    private var shouldShowAirPlayPicker = false
    private var isAirPlayPickerPresented = false
    private var mayHaveSelectedAirPlayRoute = false
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

    private let stateURL: URL
    private let defaults: UserDefaults
    private var tools: FFmpegTools {
        let path = defaults.string(forKey: "toolsDirectory") ?? ""
        return FFmpegTools(customDirectory: path.isEmpty ? nil : URL(fileURLWithPath: path))
    }

    init(stateURL: URL? = nil, defaults: UserDefaults = .standard, player: AVPlayer = AVPlayer()) {
        self.player = player
        // Keep the original data location so renaming the app preserves the queue.
        self.stateURL = stateURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Peamer/playlist.json")
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
            player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
                if !player.isExternalPlaybackActive, player.timeControlStatus != .paused { player.pause() }
                Task { @MainActor in
                    guard let self else { return }
                    let wasExternal = self.isExternal
                    self.isExternal = player.isExternalPlaybackActive
                    if self.isExternal {
                        self.mayHaveSelectedAirPlayRoute = true
                        self.isAirPlayPickerRequested = false
                        if self.playRequested, !self.isPreparing { self.playIfConnected() }
                    } else if wasExternal, !self.isPreparing, !self.isConnectingAirPlay {
                        if self.playRequested { self.mayHaveSelectedAirPlayRoute = false }
                        self.pausePlayback()
                    }
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                if !player.isExternalPlaybackActive, player.timeControlStatus != .paused { player.pause() }
                Task { @MainActor in
                    guard let self else { return }
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
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isPreparing, self.player.currentItem != nil, time.seconds.isFinite else { return }
                if self.isExternal, self.isUsingHLS { self.refreshTrackChoices() }
                self.position = min(self.duration, max(0, self.sourceOffset + time.seconds))
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
    var networkAddress: String { server.host }
    // Waiting playback still needs a Pause action, even though media is not advancing yet.
    var isPlaying: Bool { playbackControlStatus != .paused || isConnectingAirPlay }
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
            mayHaveSelectedAirPlayRoute = true
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
        if !player.isExternalPlaybackActive, !mayHaveSelectedAirPlayRoute || isAirPlayPickerPresented {
            requestAirPlayPicker()
        }
        guard !isPreparing, player.status == .readyToPlay, player.currentItem?.status == .readyToPlay else { return }
        guard player.isExternalPlaybackActive else {
            guard mayHaveSelectedAirPlayRoute, !isAirPlayPickerPresented, routePreparation == nil else { return }
            // Preroll primes an already selected route at rate zero; discovery never authorizes local playback.
            isConnectingAirPlay = true
            let generation = loadID
            routePreparation = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                guard let self, self.loadID == generation, self.playRequested else { return }
                self.routePreparation = nil
                self.player.cancelPendingPrerolls()
                self.isConnectingAirPlay = false
                if self.player.isExternalPlaybackActive { self.playIfConnected() }
                else {
                    self.mayHaveSelectedAirPlayRoute = false
                    self.requestAirPlayPicker()
                }
            }
            player.preroll(atRate: 1, completionHandler: nil)
            return
        }
        cancelRoutePreparation()
        mayHaveSelectedAirPlayRoute = true
        isAirPlayPickerRequested = false
        shouldShowAirPlayPicker = false
        player.play()
        refreshPlaybackState()
    }

    private func cancelRoutePreparation() {
        routePreparation?.cancel()
        routePreparation = nil
        player.cancelPendingPrerolls()
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
        playbackControlStatus = player.timeControlStatus
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
        if isUsingHLS, let group = audioGroup,
           let option = item.currentMediaSelection.selectedMediaOption(in: group),
           let id = audioChoices.first(where: { $0.value == option })?.key {
            let defaultID = info?.defaultAudioTrack?.id
            if id != (audioID ?? defaultID) { audioID = id == defaultID ? nil : id }
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
            let image = await Self.thumbnail(url: movie.url, at: middle, tools: tools)
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
            let image = await Self.thumbnail(url: movie.url, at: target, tools: tools)
            guard !Task.isCancelled, let self, self.current?.id == movie.id, self.seekPreviewTime == target else { return }
            if let image { self.seekPreviewCache.setObject(image, forKey: NSNumber(value: target), cost: 288 * 162 * 4) }
            self.seekPreviewImage = image
            self.isLoadingSeekPreview = false
        }
    }

    private static func thumbnail(url: URL, at seconds: Double, tools: FFmpegTools) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 288, height: 162)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let frame = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            } onCancel: { generator.cancelAllCGImageGeneration() }
            return NSImage(cgImage: frame, size: .zero)
        } catch {
            guard !Task.isCancelled, let data = try? await tools.thumbnail(url: url, at: seconds), !Task.isCancelled else { return nil }
            return NSImage(data: data)
        }
    }

    static func nativeChapters(in asset: AVAsset, duration: Double) async -> [MediaChapter] {
        var groups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
        // Unlabelled (und) chapters do not match the user's preferred languages.
        if groups.isEmpty, let locale = (try? await asset.load(.availableChapterLocales))?.first {
            groups = (try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle])) ?? []
        }
        var chapters: [MediaChapter] = []
        for (index, group) in groups.enumerated() {
            let item = AVMetadataItem.metadataItems(from: group.items, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common).first
            let title = try? await item?.load(.stringValue)
            if let chapter = MediaChapter(id: index, start: group.timeRange.start.seconds, end: CMTimeRangeGetEnd(group.timeRange).seconds,
                                          title: title, duration: duration) { chapters.append(chapter) }
        }
        return chapters.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    private func prepare(at start: Double, autoPlay: Bool, applyTrackPreferences: Bool = false,
                         allowMP4Remux: Bool = true, allowDolbyAudio: Bool = true) {
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
                guard FileManager.default.isReadableFile(atPath: movie.url.path) else { throw PlaybackError(String(format: NSLocalizedString("File not found or inaccessible: %@", comment: ""), movie.url.lastPathComponent)) }
                if applyTrackPreferences {
                    let files = await Task.detached(priority: .userInitiated) { findSubtitleFiles(for: movie.url) }.value
                    try Task.checkCancellation()
                    guard loadID == generation else { return }
                    externalSubtitleOptions = files
                }
                let asset = AVURLAsset(url: movie.url)
                let metadata: MediaInfo
                do { metadata = try await tools.probe(url: movie.url) }
                catch {
                    try Task.checkCancellation()
                    guard ["mp4", "m4v", "mov"].contains(movie.url.pathExtension.lowercased()), (try? await asset.load(.isPlayable)) == true else { throw error }
                    let seconds = try await asset.load(.duration).seconds
                    metadata = MediaInfo(duration: seconds, width: 0, height: 0, videoCodec: nil,
                                         chapters: await Self.nativeChapters(in: asset, duration: seconds))
                }
                try Task.checkCancellation()
                guard loadID == generation else { return }
                info = metadata
                duration = metadata.duration.isFinite ? max(0, metadata.duration) : 0
                // Rebuilds retain manual choices; preferences apply only when opening a video.
                if applyTrackPreferences {
                    audioID = preferences.audioTrack(in: metadata.audioTracks)
                    let captions = metadata.subtitleTracks.filter { $0.isTextSubtitle || (!preserveQuality && $0.isBitmapSubtitle) }
                    switch preferences.subtitleChoice(in: captions, files: externalSubtitleOptions, video: movie.url) {
                    case .none: subtitleID = nil; externalSubtitle = nil
                    case .embedded(let id): subtitleID = id; externalSubtitle = nil
                    case .external(let url): subtitleID = nil; externalSubtitle = url
                    }
                }
                var canPlayDirect = false
                if ["mp4", "m4v", "mov"].contains(movie.url.pathExtension.lowercased()), externalSubtitle == nil,
                   subtitleID == nil || subtitleDelay == 0, audioDelay == 0, preserveQuality {
                    canPlayDirect = (try? await asset.load(.isPlayable)) == true
                }
                try Task.checkCancellation()
                try await server.start()
                try Task.checkCancellation()
                let captionDelay = subtitleDelay
                let playbackURL: URL
                let retry: PlaybackRetry?
                if canPlayDirect {
                    retry = nil
                    isUsingHLS = false
                    isVideoCopied = false
                    sourceOffset = 0
                    playbackURL = try server.publish(file: movie.url)
                } else {
                    isUsingHLS = true
                    audioOptions = metadata.audioTracks.map { TrackOption(id: $0.id, title: self.trackTitle($0)) }
                    subtitleOptions = metadata.subtitleTracks.map { TrackOption(id: $0.id, title: self.trackTitle($0)) }
                    let newJob = HLSJob(tools: tools)
                    job = newJob
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
                    let mp4: URL?
                    if allowMP4Remux, preserveQuality, choice == .none, audioDelay == 0 {
                        mp4 = try await newJob.prepareNativeMP4(input: movie.url, info: metadata, audioTrack: audioID,
                                                              onFraction: reportFraction, progress: reportStage)
                    } else {
                        mp4 = nil
                    }
                    if let mp4 {
                        try Task.checkCancellation()
                        guard loadID == generation else { return }
                        retry = .hls
                        isUsingHLS = false
                        playbackURL = try server.publish(file: mp4)
                    } else {
                        let playlist = try await newJob.start(input: movie.url, info: metadata, audioTrack: audioID, subtitle: choice,
                            hardwareEncoding: hardwareEncoding, preserveQuality: preserveQuality, subtitleDelay: captionDelay, audioDelay: audioDelay,
                            allowDolbyAudio: allowDolbyAudio, onFraction: reportFraction, progress: reportStage)
                        try Task.checkCancellation()
                        guard loadID == generation else { return }
                        retry = newJob.usesOriginalDolby ? .stereo : nil
                        playbackURL = try server.publish(directory: playlist.deletingLastPathComponent(), playlist: playlist.lastPathComponent)
                    }
                    sourceOffset = newJob.sourceOffset
                    isVideoCopied = newJob.isVideoCopied
                }
                try Task.checkCancellation()
                guard loadID == generation else { return }
                preparationFraction = nil
                preparationStage = .loadingPlayer
                let item = AVPlayerItem(url: playbackURL)
                if isUsingHLS, let audioNames = job?.audioNames, !audioNames.isEmpty {
                    let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
                    let options = await Self.hlsTrackOptions(in: group, names: audioNames)
                    try Task.checkCancellation()
                    guard loadID == generation else { return }
                    audioGroup = group
                    audioChoices = options
                }
                if isUsingHLS, let subtitleNames = job?.subtitleNames, !subtitleNames.isEmpty {
                    let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
                    let options = await Self.hlsTrackOptions(in: group, names: subtitleNames)
                    try Task.checkCancellation()
                    guard loadID == generation else { return }
                    subtitleGroup = group
                    preparedSubtitleDelay = captionDelay
                    subtitleChoices = options
                }
                if canPlayDirect {
                    // Select tracks from the streamed asset, whose groups belong to this player item.
                    let audioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
                    let subtitleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
                    try Task.checkCancellation()
                    guard loadID == generation else { return }
                    self.audioGroup = audioGroup
                    self.subtitleGroup = subtitleGroup
                    let audioTracks = Self.nativeTracks(in: audioGroup, source: metadata.audioTracks, choices: &audioChoices)
                    var nativeSubtitleChoices: [Int: AVMediaSelectionOption] = [:]
                    let subtitleTracks = Self.nativeTracks(in: subtitleGroup, source: metadata.subtitleTracks, choices: &nativeSubtitleChoices)
                    subtitleChoices = Dictionary(uniqueKeysWithValues: nativeSubtitleChoices.map { (SubtitleChoice.embedded($0.key), $0.value) })
                    audioOptions = audioTracks.map { TrackOption(id: $0.id, title: $0.title ?? "") }
                    subtitleOptions = subtitleTracks.map { TrackOption(id: $0.id, title: $0.title ?? "") }
                    if applyTrackPreferences {
                        audioID = preferences.audioTrack(in: audioTracks)
                        if case .embedded(let id) = preferences.subtitleChoice(in: subtitleTracks, files: [], video: movie.url) { subtitleID = id }
                        else { subtitleID = nil }
                        if subtitleID != nil, subtitleDelay != 0 {
                            prepare(at: start, autoPlay: playRequested)
                            return
                        }
                    }
                }
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
                            self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                                Task { @MainActor in
                                    guard let self, self.loadID == generation else { return }
                                    self.releasePreviousPlayback()
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
                if subtitleGroup != nil || (isUsingHLS && audioGroup != nil) {
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
            } catch is CancellationError {
            } catch {
                playbackFailed(error.localizedDescription, generation: generation, retry: job?.usesOriginalDolby == true ? .stereo : nil)
            }
        }
    }

    private enum PlaybackRetry {
        case hls, stereo
    }

    private func playbackFailed(_ reason: String, generation: UUID, retry: PlaybackRetry?) {
        guard loadID == generation else { return }
        if let retry {
            prepare(at: position, autoPlay: playRequested, allowMP4Remux: false, allowDolbyAudio: retry == .hls)
        } else {
            errorMessage = reason
            cancelPlayback()
        }
    }

    private static func hlsTrackOptions<ID: Hashable>(in group: AVMediaSelectionGroup?, names: [ID: String]) async -> [ID: AVMediaSelectionOption] {
        let choices = Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) })
        let nameIdentifier = AVMetadataIdentifier(rawValue: "m3u8/NAME")
        var options: [ID: AVMediaSelectionOption] = [:]
        for option in group?.options ?? [] {
            // AVPlayer can display several renditions using the same localized language name.
            let attribute = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: nameIdentifier).first
            let name = (try? await attribute?.load(.stringValue)) ?? option.displayName
            if let choice = choices[name] { options[choice] = option }
        }
        return options
    }

    private static func nativeTracks(in group: AVMediaSelectionGroup?, source: [MediaTrack], choices: inout [Int: AVMediaSelectionOption]) -> [MediaTrack] {
        var remaining = source
        let options = group?.options ?? []
        // AVFoundation adds forced-only views of MOV text tracks; they are not extra source streams.
        let full = AVMediaSelectionGroup.mediaSelectionOptions(from: options, withoutMediaCharacteristics: [.containsOnlyForcedSubtitles])
        return (full.isEmpty ? options : full).enumerated().compactMap { index, option -> MediaTrack? in
            guard source.isEmpty || !remaining.isEmpty else { return nil }
            let language = option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier
            let code = MediaLanguages.normalized(language)
            // Native groups can omit or reorder streams; retain FFmpeg's global stream IDs.
            let match = code.flatMap { code in remaining.firstIndex { MediaLanguages.normalized($0.language) == code } } ?? remaining.indices.first
            let track = match.map { remaining.remove(at: $0) }
            let id = track?.id ?? (source.map(\.id).max() ?? -1) + index + 1
            var disposition = track?.disposition ?? [:]
            if option == group?.defaultOption { disposition["default"] = 1 }
            if option.hasMediaCharacteristic(.isOriginalContent) { disposition["original"] = 1 }
            if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) { disposition["forced"] = 1 }
            choices[id] = option
            return MediaTrack(id: id, codec: track?.codec ?? "unknown", language: language ?? track?.language,
                              title: option.displayName, disposition: disposition)
        }
    }

    private func finished(generation: UUID) {
        guard loadID == generation else { return }
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
        if keepingItem, let item = player.currentItem {
            // Keep the old item and its URLs alive until replacement is ready so AVKit retains the route.
            if previousPlayback?.item !== item {
                releasePreviousPlayback()
                previousPlayback = (item, server, job)
            }
            else { job?.stop(); server.stop() }
            server = MediaHTTPServer()
        } else {
            if player.currentItem != nil { player.replaceCurrentItem(with: nil) }
            job?.stop()
            server.revokeAll()
            releasePreviousPlayback()
        }
        job = nil
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

    private func releasePreviousPlayback() {
        previousPlayback?.job?.stop()
        previousPlayback?.server.stop()
        previousPlayback = nil
    }

    private func trackTitle(_ track: MediaTrack) -> String {
        [track.title, track.language?.uppercased(), track.codec.uppercased(), track.channels.map { "\($0) ch" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

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
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            playlist = try JSONDecoder().decode(Playlist.self, from: Data(contentsOf: stateURL))
            if playlist.history == nil {
                playlist.history = []
                for item in playlist.items { playlist.recordHistory(item) }
            }
        }
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
