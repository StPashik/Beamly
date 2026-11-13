import Foundation

public struct MediaTrack: Codable, Identifiable, Sendable, Equatable {
    /// The file's global FFmpeg stream index, not an index within audio or subtitles.
    public let id: Int
    public let codec: String
    public let language: String?
    public let title: String?
    public let channels: Int?
    public var profile: String?
    public var disposition: [String: Int]?

    public var isDefault: Bool { disposition?["default"] == 1 }
    public var isOriginal: Bool { disposition?["original"] == 1 }
    public var isForced: Bool { disposition?["forced"] == 1 }
    public var isCommentary: Bool { disposition?["comment"] == 1 }
    public var isTextSubtitle: Bool { ["subrip", "ass", "ssa", "webvtt", "mov_text", "text"].contains(codec) }
    public var isBitmapSubtitle: Bool { ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"].contains(codec) }

    public init(id: Int, codec: String, language: String? = nil, title: String? = nil, channels: Int? = nil, profile: String? = nil, disposition: [String: Int]? = nil) {
        self.id = id
        self.codec = codec
        self.language = language
        self.title = title
        self.channels = channels
        self.profile = profile
        self.disposition = disposition
    }
}

public struct MediaChapter: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String?

    public init?(id: Int, start: Double, end: Double, title: String?, duration: Double) {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0,
              start >= 0, start < duration, end > start else { return nil }
        self.id = id
        self.start = start
        self.end = min(end, duration)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title?.isEmpty == false ? title : nil
    }
}

public struct MediaInfo: Codable, Sendable, Equatable {
    public let duration: Double
    public let width: Int
    public let height: Int
    public let videoCodec: String?
    public let audioTracks: [MediaTrack]
    public let subtitleTracks: [MediaTrack]
    // Optional so metadata encoded before chapter support still decodes.
    public var chapters: [MediaChapter]?
    public var videoProfile: String?
    public var pixelFormat: String?
    public var videoLevel: Int?
    public var frameRate: Double = 0
    public var colorTransfer: String?
    public var colorPrimaries: String?
    public var colorSpace: String?
    public var hasDolbyVision = false
    public var startTime: Double = 0
    public var defaultAudioTrack: MediaTrack? { audioTracks.first(where: \.isDefault) ?? audioTracks.first }

    public var isHDR: Bool { ["smpte2084", "arib-std-b67"].contains(colorTransfer) }
    public var videoRange: String { colorTransfer == "smpte2084" ? "PQ" : colorTransfer == "arib-std-b67" ? "HLG" : "SDR" }

    public var canCopyVideo: Bool {
        guard !hasDolbyVision, width > 0, width <= 4096, height > 0, height <= 2160,
              frameRate >= 0, frameRate <= (isHDR ? 30 : 60) else { return false }
        if isHDR, pixelFormat != "yuv420p10le" || videoProfile != "Main 10" || colorPrimaries != "bt2020" || !["bt2020nc", "bt2020c"].contains(colorSpace) { return false }
        if videoCodec == "hevc" {
            return (videoProfile == nil || ["Main", "Main 10"].contains(videoProfile)) &&
                (pixelFormat == nil || ["yuv420p", "yuv420p10le"].contains(pixelFormat)) && (videoLevel ?? 0) <= 153
        }
        return videoCodec == "h264" && !isHDR &&
            (pixelFormat == nil || pixelFormat == "yuv420p") && (videoLevel ?? 0) <= 51
    }

    public init(duration: Double, width: Int, height: Int, videoCodec: String?, audioTracks: [MediaTrack] = [], subtitleTracks: [MediaTrack] = [], chapters: [MediaChapter] = []) {
        self.duration = duration
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.chapters = chapters
    }
}

public let videoFileExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpeg", "mpg", "m2ts", "mts", "ts", "m2t", "vob", "flv", "wmv", "ogm", "ogg", "rmvb", "divx", "3gp"]
