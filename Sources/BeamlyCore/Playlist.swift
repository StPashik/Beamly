import Foundation

public struct PlaylistItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public var position: Double
    public var duration: Double?
    // Optional so queues saved before subtitle timing support still decode.
    public var subtitleDelay: Double?
    public var audioDelay: Double?

    public init(url: URL) {
        id = UUID()
        self.url = url.standardizedFileURL
        position = 0
    }

    public var title: String { url.deletingPathExtension().lastPathComponent }
}

public struct WatchHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var video: PlaylistItem
    public var watchedAt: Date
    public var id: URL { video.url }
    public var isFinished: Bool { video.duration.map { video.position >= $0 - 3 } ?? false }
}

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, one, all
}

public struct Playlist: Codable, Equatable, Sendable {
    public var items: [PlaylistItem] = []
    public var currentID: UUID?
    // Optional so existing queues migrate without losing their saved positions.
    public var history: [WatchHistoryEntry]?
    public var repeatMode: RepeatMode = .off
    public var shuffle = false {
        didSet { if oldValue != shuffle { shuffleOrder.removeAll() } }
    }
    private var shuffleOrder: [UUID] = []

    // Navigation order is temporary; restored playlists begin a fresh shuffle cycle.
    private enum CodingKeys: CodingKey { case items, currentID, repeatMode, shuffle, history }

    public init() {}

    public var current: PlaylistItem? { items.first { $0.id == currentID } }

    public mutating func recordHistory(_ item: PlaylistItem, at date: Date = Date()) {
        guard item.url.isFileURL, item.position.isFinite, item.position >= 0,
              item.position > 0 || item.audioDelay != nil || item.subtitleDelay != nil,
              let duration = item.duration, duration.isFinite, duration > 0 else { return }
        var saved = item
        saved.position = min(item.position, duration)
        history = (history ?? []).filter { $0.id != item.url }
        history?.insert(WatchHistoryEntry(video: saved, watchedAt: date), at: 0)
        // Bound local metadata; the source movies are never modified or deleted.
        history = Array((history ?? []).prefix(100))
    }

    public mutating func append(_ urls: [URL]) {
        var existing = Set(items.map { $0.url })
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            if existing.insert(normalized).inserted {
                var item = PlaylistItem(url: normalized)
                if let saved = history?.first(where: { $0.id == normalized })?.video {
                    item.position = saved.position
                    item.duration = saved.duration
                    item.subtitleDelay = saved.subtitleDelay
                    item.audioDelay = saved.audioDelay
                }
                items.append(item)
            }
        }
        if currentID == nil { currentID = items.first?.id }
    }

    public mutating func next(finishing: Bool = false) -> UUID? {
        guard let index = items.firstIndex(where: { $0.id == currentID }) else { return items.first?.id }
        if finishing && repeatMode == .one { return currentID }
        if shuffle {
            updateShuffleOrder()
            guard let shuffledIndex = shuffleOrder.firstIndex(of: items[index].id) else { return nil }
            if shuffledIndex + 1 < shuffleOrder.count { return shuffleOrder[shuffledIndex + 1] }
            guard repeatMode == .all else { return nil }
            shuffleOrder.shuffle()
            if shuffleOrder.count > 1, shuffleOrder.first == currentID { shuffleOrder.swapAt(0, 1) }
            return shuffleOrder.first
        }
        if index + 1 < items.count { return items[index + 1].id }
        return repeatMode == .all ? items.first?.id : nil
    }

    public mutating func previous() -> UUID? {
        if shuffle {
            updateShuffleOrder()
            guard let currentID, let index = shuffleOrder.firstIndex(of: currentID), index > 0 else { return nil }
            return shuffleOrder[index - 1]
        }
        guard let index = items.firstIndex(where: { $0.id == currentID }), index > 0 else { return nil }
        return items[index - 1].id
    }

    private mutating func updateShuffleOrder() {
        let ids = items.map(\.id)
        let valid = Set(ids)
        shuffleOrder.removeAll { !valid.contains($0) }
        if shuffleOrder.isEmpty {
            shuffleOrder = [currentID].compactMap { $0 } + ids.filter { $0 != currentID }.shuffled()
        } else {
            let known = Set(shuffleOrder)
            shuffleOrder.append(contentsOf: ids.filter { !known.contains($0) }.shuffled())
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.currentID == rhs.currentID &&
        lhs.repeatMode == rhs.repeatMode && lhs.shuffle == rhs.shuffle
    }

    public mutating func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if currentID == id { currentID = items.isEmpty ? nil : items[min(index, items.count - 1)].id }
    }

    public mutating func remember(position: Double, duration: Double) {
        guard let index = items.firstIndex(where: { $0.id == currentID }) else { return }
        items[index].position = position.isFinite ? max(0, position) : 0
        if duration.isFinite && duration > 0 { items[index].duration = duration }
    }
}

public func mediaTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
    let value = Int(seconds)
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}
