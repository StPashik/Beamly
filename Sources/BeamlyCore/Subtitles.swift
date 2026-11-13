import Foundation

public enum SubtitleChoice: Hashable, Sendable {
    case none
    case embedded(Int)
    case external(URL)
}

public func findSubtitleFiles(for video: URL) -> [URL] {
    guard video.isFileURL else { return [] }
    let stem = video.deletingPathExtension().lastPathComponent.lowercased()
    let files = (try? FileManager.default.contentsOfDirectory(at: video.deletingLastPathComponent(),
        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
    let otherMovies = files.filter {
        videoFileExtensions.contains($0.pathExtension.lowercased()) &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.map { $0.deletingPathExtension().lastPathComponent.lowercased() }.filter { $0.hasPrefix(stem + ".") }
    return files.filter { file in
        let name = file.deletingPathExtension().lastPathComponent.lowercased()
        return ["srt", "ass", "ssa", "vtt"].contains(file.pathExtension.lowercased()) &&
            (name == stem || name.hasPrefix(stem + ".")) &&
            !otherMovies.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) &&
            (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
            FileManager.default.isReadableFile(atPath: file.path)
    }.sorted { lhs, rhs in
        let leftExact = lhs.deletingPathExtension().lastPathComponent.lowercased() == stem
        let rightExact = rhs.deletingPathExtension().lastPathComponent.lowercased() == stem
        if leftExact != rightExact { return leftExact }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }
}

struct CaptionRendition {
    let choice: SubtitleChoice
    let name: String
    let language: String
    let stem: String
}

enum SubtitleRendering {
    case text(String)
    case bitmap(Int)
}

@MainActor
enum SubtitlePreparation {
    static func embeddedRenditions(_ selected: SubtitleChoice, info: MediaInfo) throws -> [CaptionRendition] {
        if case .embedded(let id) = selected {
            guard let track = info.subtitleTracks.first(where: { $0.id == id }) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("The selected subtitle track is missing from the file.", comment: ""))
            }
            guard track.isTextSubtitle else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("Bitmap subtitles require video conversion. Choose text subtitles or turn off Preserve video quality.", comment: ""))
            }
        }
        var names: Set<String> = []
        return info.subtitleTracks.filter(\.isTextSubtitle).map { track in
            let choice = SubtitleChoice.embedded(track.id)
            let language = MediaLanguages.normalized(track.language) ?? "und"
            let name = track.title ?? Locale(identifier: "en").localizedString(forLanguageCode: language) ?? "Subtitles"
            let uniqueName = HLSPlaylist.uniqueRenditionName(name, fallback: "Subtitles", names: &names)
            return CaptionRendition(choice: choice, name: uniqueName, language: language,
                                    stem: choice == selected ? "captions" : "captions-\(track.id)")
        }
    }

    static func extractionArguments(_ renditions: [CaptionRendition], in directory: URL) -> [String] {
        renditions.flatMap { rendition in
            let stream: String
            if case .embedded(let id) = rendition.choice { stream = "0:\(id)" }
            else { stream = "0:s:0" }
            return ["-map", stream, "-c:s", "webvtt", directory.appendingPathComponent(rendition.stem + ".vtt").path]
        }
    }

    static func extract(_ renditions: [CaptionRendition], from source: URL, ffmpeg: URL, in directory: URL) async throws {
        guard !renditions.isEmpty else { return }
        let arguments = ["-v", "error", "-nostdin", "-y", "-copyts", "-i", source.path] + extractionArguments(renditions, in: directory)
        _ = try await ProcessRunner().run(executable: ffmpeg, arguments: arguments)
    }

    static func extractEmbedded(_ embedded: [CaptionRendition], selected: SubtitleChoice,
                                input: URL, ffmpeg: URL, in directory: URL) async throws -> [CaptionRendition] {
        do {
            try await extract(embedded, from: input, ffmpeg: ffmpeg, in: directory)
            return embedded
        } catch where !MediaPipelineError.isInsufficientSpace(error) {
            try Task.checkCancellation()
            let required = embedded.filter { $0.choice == selected }
            try await extract(required, from: input, ffmpeg: ffmpeg, in: directory)
            return required
        }
    }

    static func externalRendition(_ url: URL, after embedded: [CaptionRendition]) throws -> CaptionRendition {
        _ = try validatedExtension(for: url)
        var names = Set(embedded.map(\.name))
        let name = HLSPlaylist.uniqueRenditionName(url.lastPathComponent, fallback: "Subtitles", names: &names)
        return CaptionRendition(choice: .external(url), name: name, language: "und", stem: "captions")
    }

    static func extractRenditions(_ selected: SubtitleChoice, embedded: [CaptionRendition], alreadyExtracted: Bool,
                                  input: URL, cache: URL, ffmpeg: URL) async throws -> [CaptionRendition] {
        guard !embedded.isEmpty || selected != .none else { return [] }
        let privateFolder = cache.appendingPathComponent(".inputs")
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        var renditions = embedded
        if !alreadyExtracted {
            renditions = try await extractEmbedded(embedded, selected: selected, input: input, ffmpeg: ffmpeg, in: privateFolder)
        }
        if case .external(let url) = selected {
            let rendition = try externalRendition(url, after: embedded)
            try await extract([rendition], from: url, ffmpeg: ffmpeg, in: privateFolder)
            renditions.append(rendition)
        }
        return renditions
    }

    static func writeRenditions(_ renditions: [CaptionRendition], selected: SubtitleChoice, info: MediaInfo,
                                cache: URL, sourceOffset: Double, subtitleDelay: Double) throws -> [CaptionRendition] {
        try renditions.filter { rendition in
            try Task.checkCancellation()
            do {
                try writeRendition(rendition, info: info, cache: cache, sourceOffset: sourceOffset, subtitleDelay: subtitleDelay)
                return true
            } catch {
                if rendition.choice == selected { throw error }
                return false
            }
        }
    }

    static func writeOptionalRenditions(_ renditions: [CaptionRendition], extracted: [CaptionRendition],
                                        info: MediaInfo, cache: URL, sourceOffset: Double, subtitleDelay: Double,
                                        videoDuration: Double) {
        for caption in renditions {
            if extracted.contains(where: { $0.choice == caption.choice }),
               (try? writeRendition(caption, info: info, cache: cache, sourceOffset: sourceOffset,
                       subtitleDelay: subtitleDelay, videoDuration: videoDuration)) != nil {
                continue
            }
            // Preserve an already advertised timeline even when an optional caption is unreadable.
            try? WebVTTCaptions.header.write(
                to: cache.appendingPathComponent(caption.stem + ".vtt"), atomically: true, encoding: .utf8)
        }
    }

    static func writeRendition(_ rendition: CaptionRendition, info: MediaInfo, cache: URL, sourceOffset: Double,
                               subtitleDelay: Double, videoDuration: Double? = nil) throws {
        let duration = max(0.01, (videoDuration ?? info.duration) - sourceOffset)
        let raw = cache.appendingPathComponent(".inputs").appendingPathComponent(rendition.stem + ".vtt")
        let size = try raw.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw MediaPipelineError.invalidMedia(NSLocalizedString("The subtitle file is too large.", comment: "")) }
        let origin: Double
        if case .embedded = rendition.choice { origin = sourceOffset + info.startTime }
        else { origin = sourceOffset }
        let captions = try WebVTTCaptions.retimed(String(contentsOf: raw, encoding: .utf8), offset: origin - subtitleDelay, duration: duration)
        try captions.write(to: cache.appendingPathComponent(rendition.stem + ".vtt"), atomically: true, encoding: .utf8)
        try HLSPlaylist.writeCaptionPlaylist(rendition, duration: duration, in: cache)
    }

    static func rendering(_ subtitle: SubtitleChoice, input: URL, info: MediaInfo, directory: URL) throws -> SubtitleRendering? {
        guard subtitle != .none else { return nil }
        let inputs = directory.appendingPathComponent(".inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        switch subtitle {
        case .none: return nil
        case .embedded(let index):
            guard let ordinal = info.subtitleTracks.firstIndex(where: { $0.id == index }) else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("The selected subtitle track is missing from the file.", comment: ""))
            }
            if info.subtitleTracks[ordinal].isBitmapSubtitle {
                return .bitmap(index)
            }
            // Fixed relative symlinks keep filenames out of FFmpeg's filter expression parser.
            try FileManager.default.createSymbolicLink(at: inputs.appendingPathComponent("source"), withDestinationURL: input)
            return .text("subtitles=filename=.inputs/source:si=\(ordinal)")
        case .external(let url):
            let ext = try validatedExtension(for: url)
            let name = "subtitle.\(ext)"
            try FileManager.default.createSymbolicLink(at: inputs.appendingPathComponent(name), withDestinationURL: url)
            return .text("subtitles=filename=.inputs/\(name)")
        }
    }

    private static func validatedExtension(for url: URL) throws -> String {
        try validateLocalFile(url)
        let ext = url.pathExtension.lowercased()
        guard ["srt", "ass", "ssa", "vtt", "webvtt", "sub", "txt", "mpl", "mpl2"].contains(ext) else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("SRT, ASS, SSA and VTT text subtitles are supported.", comment: ""))
        }
        return ext
    }
}

enum WebVTTCaptions {
    static let header = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n"

    static func retimed(_ text: String, offset: Double, duration: Double) throws -> String {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        guard text.hasPrefix("WEBVTT"), offset.isFinite, duration.isFinite, duration > 0, duration < 1_000_000_000 else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("The subtitle timestamps are invalid.", comment: ""))
        }
        var result = header
        for block in blocks.dropFirst() where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains(" --> ") }) else { continue }
            let parts = lines[index].components(separatedBy: " --> ")
            let endParts = parts[1].split(separator: " ", maxSplits: 1)
            guard let start = seconds(parts[0]), let endText = endParts.first, let end = seconds(String(endText)), end >= start else {
                throw MediaPipelineError.invalidMedia(NSLocalizedString("The subtitle timestamps are invalid.", comment: ""))
            }
            if end <= offset || start - offset >= duration { continue }
            lines[index] = "\(timestamp(max(0, start - offset))) --> \(timestamp(min(duration, end - offset)))"
            if endParts.count == 2 { lines[index] += " \(endParts[1])" }
            result += lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n\n"
        }
        return result
    }

    private static func seconds(_ value: String) -> Double? {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Double($0) }
        guard fields.count == parts.count, (2...3).contains(parts.count), parts.allSatisfy({ $0.isFinite && $0 >= 0 }),
              parts.last! < 60, parts[parts.count - 2] < 60 else { return nil }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        return total < 1_000_000_000 ? total : nil
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
