import Foundation

enum FFmpegProgress {
    static func fraction(in file: URL, size: Int, duration: Double, frameRate: Double) -> Double? {
        guard duration.isFinite, duration > 0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(max(0, size - 2048)))) != nil,
              let data = try? handle.read(upToCount: 2048) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        func last(_ key: String) -> Double {
            lines.last { $0.hasPrefix(key) }.flatMap { Double($0.dropFirst(key.count)) } ?? 0
        }
        // With separate audio renditions, FFmpeg's time report can lag behind the copied video frames.
        let seconds = max(last("out_time_us=") / 1_000_000, frameRate > 0 ? last("frame=") / frameRate : 0)
        return seconds.isFinite && seconds > 0 ? min(0.99, seconds / duration) : nil
    }
}
