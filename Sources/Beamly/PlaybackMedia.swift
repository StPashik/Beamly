import AppKit
import AVFoundation
import BeamlyCore

@MainActor
enum PlaybackMedia {
    static func thumbnail(url: URL, at seconds: Double, tools: FFmpegTools) async -> NSImage? {
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

    static func metadata(for url: URL, asset: AVURLAsset, tools: FFmpegTools) async throws -> MediaInfo {
        do { return try await tools.probe(url: url) }
        catch {
            try Task.checkCancellation()
            guard isNativeContainer(url), (try? await asset.load(.isPlayable)) == true else { throw error }
            let seconds = try await asset.load(.duration).seconds
            return MediaInfo(duration: seconds, width: 0, height: 0, videoCodec: nil,
                             chapters: await nativeChapters(in: asset, duration: seconds))
        }
    }

    static func isNativeContainer(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    static func hlsTrackOptions<ID: Hashable>(in group: AVMediaSelectionGroup?, names: [ID: String]) async -> [ID: AVMediaSelectionOption] {
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

    static func nativeTracks(in group: AVMediaSelectionGroup?, source: [MediaTrack], choices: inout [Int: AVMediaSelectionOption]) -> [MediaTrack] {
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

    static func title(for track: MediaTrack) -> String {
        [track.title, track.language?.uppercased(), track.codec.uppercased(), track.channels.map { "\($0) ch" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
