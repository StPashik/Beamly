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

enum SubtitleRendering {
    case text(String)
    case bitmap(Int)
}

enum WebVTTCaptions {
    static func retimed(_ text: String, offset: Double, duration: Double) throws -> String {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        guard text.hasPrefix("WEBVTT"), offset.isFinite, duration.isFinite, duration > 0, duration < 1_000_000_000 else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("The subtitle timestamps are invalid.", comment: ""))
        }
        var result = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n"
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
