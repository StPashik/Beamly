import Foundation

public enum MediaLanguages {
    public static let codes = Array(Set(Locale.LanguageCode.isoLanguageCodes.compactMap {
        $0.identifier(.alpha2).flatMap { $0.count == 2 ? $0 : nil }
    })).sorted()

    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let canonical = Locale.canonicalLanguageIdentifier(from: value)
        guard let code = Locale.LanguageCode(canonical).identifier(.alpha2), codes.contains(code) else { return nil }
        return code
    }
}

public struct TrackPreferences: Sendable {
    public let audio: String
    public let subtitles: String

    public init(audio: String = "default", subtitles: String = "automatic") {
        self.audio = audio == "original" ? audio : MediaLanguages.normalized(audio) ?? "default"
        self.subtitles = ["automatic", "off"].contains(subtitles) ? subtitles : MediaLanguages.normalized(subtitles) ?? "automatic"
    }

    public func audioTrack(in tracks: [MediaTrack]) -> Int? {
        let matches = tracks.filter { track in
            !track.isCommentary && (audio == "original" ? track.isOriginal :
                MediaLanguages.normalized(track.language) == audio)
        }
        return (matches.first(where: \.isDefault) ?? matches.first)?.id
    }

    public func subtitleChoice(in tracks: [MediaTrack], files: [URL], video: URL) -> SubtitleChoice {
        if subtitles == "off" { return .none }
        if subtitles == "automatic" {
            let exact = files.first { $0.deletingPathExtension().lastPathComponent.lowercased() == video.deletingPathExtension().lastPathComponent.lowercased() }
            return (exact ?? (files.count == 1 ? files.first : nil)).map(SubtitleChoice.external) ?? .none
        }
        let prefix = video.deletingPathExtension().lastPathComponent.lowercased() + "."
        func suffix(_ file: URL) -> [String] {
            let stem = file.deletingPathExtension().lastPathComponent.lowercased()
            guard stem.hasPrefix(prefix) else { return [] }
            return String(stem.dropFirst(prefix.count)).components(separatedBy: ".")
        }
        let external = files.filter { MediaLanguages.normalized(suffix($0).first) == subtitles }
        let embedded = tracks.filter { MediaLanguages.normalized($0.language) == subtitles }
        if let file = external.first(where: { !suffix($0).contains("forced") }) { return .external(file) }
        let full = embedded.filter { !$0.isForced }
        if let track = full.first(where: \.isDefault) ?? full.first { return .embedded(track.id) }
        if let file = external.first { return .external(file) }
        return (embedded.first(where: \.isDefault) ?? embedded.first).map { .embedded($0.id) } ?? .none
    }
}
