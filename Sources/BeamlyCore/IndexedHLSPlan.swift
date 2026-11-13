import Foundation

struct IndexedHLSSegment {
    let name: String
    let start: Double
    let end: Double

    var duration: Double { end - start }
}

struct IndexedHLSAudio {
    let track: MediaTrack
    let segments: [IndexedHLSSegment]
    var padding: Padding?

    struct Padding {
        let bitrate: Int
        let segments: [IndexedHLSSegment]
    }

    var playlistSegments: [IndexedHLSSegment] { segments + (padding?.segments ?? []) }
}

struct IndexedHLSPlan {
    static let segmentLength = 6
    static let maximumKeyframeInterval = 12.0

    let video: [IndexedHLSSegment]
    let previews: [IndexedHLSSegment]
    let audio: [IndexedHLSAudio]

    init?(keyframes: [Double], duration: Double, isHEVC: Bool, audio: [IndexedHLSAudio]) {
        // The HLS muxer cuts on the first keyframe at or beyond each successive time threshold.
        var starts = [0.0]
        for time in keyframes.dropFirst() where time >= Double(Self.segmentLength * starts.count) {
            starts.append(time)
        }
        guard starts.count >= 2 else { return nil }

        func segments(_ times: [Double], prefix: String) -> [IndexedHLSSegment] {
            zip(times, Array(times.dropFirst()) + [duration]).enumerated().map { index, pair in
                IndexedHLSSegment(name: prefix + String(format: "%06d.m4s", index), start: pair.0, end: pair.1)
            }
        }
        let video = segments(starts, prefix: "segment_0_")
        let previews = isHEVC ? [] : segments(keyframes, prefix: "iframe-")
        let maximumKeyframeInterval = Self.maximumKeyframeInterval
        let maximumSegmentDuration = Double(Self.segmentLength) + maximumKeyframeInterval
        guard zip(keyframes, keyframes.dropFirst() + [duration]).allSatisfy({ (0.001...maximumKeyframeInterval).contains($1 - $0) }),
              video.allSatisfy({ (0.01...maximumSegmentDuration).contains($0.duration) }) else {
            return nil
        }
        self.video = video
        self.previews = previews
        self.audio = audio
    }

    var targetDuration: Int { Int(ceil(video.map(\.duration).max() ?? 1)) }

    var audioInitializationNames: [String] { audio.indices.map { "init_\($0 + 1).mp4" } }

    var firstSegmentNames: [String] {
        video.prefix(2).map(\.name) + previews.prefix(1).map(\.name) + audio.flatMap { $0.segments.prefix(2).map(\.name) }
    }

    var pendingSegmentNames: [String] {
        // Silence padding is already written before the playlist is published.
        video.map(\.name) + previews.map(\.name) + audio.flatMap { $0.segments.map(\.name) }
    }
}
