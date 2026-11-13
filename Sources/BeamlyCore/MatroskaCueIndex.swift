import Foundation

enum MatroskaCueIndex {
    // Follow the SeekHead so reading the index never requires scanning the movie payload.
    static func videoKeyframes(in url: URL) throws -> [Double] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        let header = try Element.read(from: file, at: 0, limit: length)
        let segment = try Element.read(from: file, at: header.end, limit: length, allowUnknownSize: true)
        guard header.id == .header, segment.id == .segment else { throw invalidIndex }
        let seekHead = try Element.read(from: file, at: segment.start, limit: segment.end)
        guard seekHead.id == .seekHead else { throw invalidIndex }
        let entries = try seekHead.children(in: file).filter { $0.id == .seek }.map { try $0.children(in: file) }
        func indexed(_ id: ID) throws -> Element {
            for entry in entries {
                guard let target = entry.first(where: { $0.id == .seekID }), try target.unsigned(in: file) == id.rawValue,
                      let position = entry.first(where: { $0.id == .seekPosition }) else { continue }
                let offset = try position.unsigned(in: file)
                guard offset < segment.end - segment.start else { throw invalidIndex }
                let element = try Element.read(from: file, at: segment.start + offset, limit: segment.end)
                guard element.id == id else { throw invalidIndex }
                return element
            }
            throw invalidIndex
        }

        let info = try indexed(.info).children(in: file)
        let scale = try info.first { $0.id == .timestampScale }?.unsigned(in: file) ?? 1_000_000
        guard scale > 0 else { throw invalidIndex }
        let tracks = try indexed(.tracks).children(in: file).filter { $0.id == .trackEntry }
        let videoTracks = try tracks.compactMap { track -> UInt64? in
            let fields = try track.children(in: file)
            guard try fields.first(where: { $0.id == .trackType })?.unsigned(in: file) == 1 else { return nil }
            guard !fields.contains(where: { $0.id == .trackTimestampScale }),
                  let number = fields.first(where: { $0.id == .trackNumber }) else { throw invalidIndex }
            return try number.unsigned(in: file)
        }
        guard videoTracks.count == 1, let track = videoTracks.first else { throw invalidIndex }
        let cues = try indexed(.cues).children(in: file)
        let times = try cues.compactMap { cue -> Double? in
            try Task.checkCancellation()
            guard cue.id == .cuePoint else { return nil }
            let fields = try cue.children(in: file)
            for position in fields where position.id == .cueTrackPositions {
                let location = try position.children(in: file)
                guard try location.first(where: { $0.id == .cueTrack })?.unsigned(in: file) == track else { continue }
                guard let time = fields.first(where: { $0.id == .cueTime }),
                      let cluster = location.first(where: { $0.id == .cueClusterPosition }),
                      try cluster.unsigned(in: file) < segment.end - segment.start else { throw invalidIndex }
                return Double(try time.unsigned(in: file)) * Double(scale) / 1_000_000_000
            }
            return nil
        }
        return Array(Set(times)).sorted()
    }

    private static var invalidIndex: CocoaError { CocoaError(.fileReadCorruptFile) }

    private enum ID: UInt64 {
        case header = 0x1A45DFA3
        case segment = 0x18538067
        case seekHead = 0x114D9B74
        case seek = 0x4DBB
        case seekID = 0x53AB
        case seekPosition = 0x53AC
        case info = 0x1549A966
        case timestampScale = 0x2AD7B1
        case tracks = 0x1654AE6B
        case trackEntry = 0xAE
        case trackType = 0x83
        case trackTimestampScale = 0x23314F
        case trackNumber = 0xD7
        case cues = 0x1C53BB6B
        case cuePoint = 0xBB
        case cueTrackPositions = 0xB7
        case cueTrack = 0xF7
        case cueTime = 0xB3
        case cueClusterPosition = 0xF1
    }

    private struct Element {
        let id: ID?
        let start: UInt64
        let end: UInt64

        static func read(from file: FileHandle, at offset: UInt64, limit: UInt64,
                         allowUnknownSize: Bool = false) throws -> Self {
            guard offset < limit else { throw invalidIndex }
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: Int(min(12, limit - offset))) ?? Data()
            guard let first = data.first, first != 0 else { throw invalidIndex }
            let idWidth = first.leadingZeroBitCount + 1
            guard idWidth <= 4, data.count > idWidth, data[idWidth] != 0 else { throw invalidIndex }
            let sizeWidth = data[idWidth].leadingZeroBitCount + 1
            let width = idWidth + sizeWidth
            guard data.count >= width else { throw invalidIndex }
            let id = ID(rawValue: data.prefix(idWidth).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
            let sizeMask = (UInt64(1) << (7 * sizeWidth)) - 1
            let size = data[idWidth..<width].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & sizeMask
            let start = offset + UInt64(width)
            if size == sizeMask {
                guard allowUnknownSize else { throw invalidIndex }
                return Self(id: id, start: start, end: limit)
            }
            guard size <= limit - start else { throw invalidIndex }
            return Self(id: id, start: start, end: start + size)
        }

        func children(in file: FileHandle) throws -> [Self] {
            guard end - start <= 4 * 1024 * 1024 else { throw invalidIndex }
            var children: [Self] = []
            var offset = start
            while offset < end {
                guard children.count < 25_000 else { throw invalidIndex }
                let child = try Self.read(from: file, at: offset, limit: end)
                children.append(child)
                offset = child.end
            }
            return children
        }

        func unsigned(in file: FileHandle) throws -> UInt64 {
            let length = Int(end - start)
            guard (1...8).contains(length) else { throw invalidIndex }
            try file.seek(toOffset: start)
            guard let data = try file.read(upToCount: length), data.count == length else { throw invalidIndex }
            return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
    }
}
