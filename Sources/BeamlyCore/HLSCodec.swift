import AVFoundation
import Foundation

enum HLSCodec {
    static func identifier(at url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        if let track = try await asset.loadTracks(withMediaType: .video).first,
           let description = try await track.load(.formatDescriptions).first,
           let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
            if let data = atoms["hvcC"] as? Data { return try hevc(data) }
            if let data = atoms["avcC"] as? Data, data.count >= 4, data[0] == 1 {
                return String(format: "avc1.%02X%02X%02X", data[1], data[2], data[3])
            }
        }
        throw MediaPipelineError.invalidMedia(NSLocalizedString("The HLS video codec could not be identified.", comment: ""))
    }

    static func hevc(_ data: Data) throws -> String {
        guard data.count >= 23, data[0] == 1 else {
            throw MediaPipelineError.invalidMedia(NSLocalizedString("The HLS video codec could not be identified.", comment: ""))
        }
        let spaces = ["", "A", "B", "C"]
        let profile = "\(spaces[Int(data[1] >> 6)])\(data[1] & 31)"
        var flags = data[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var reversed: UInt32 = 0
        for _ in 0..<32 { reversed = (reversed << 1) | (flags & 1); flags >>= 1 }
        var constraints = Array(data[6..<12])
        while constraints.count > 1, constraints.last == 0 { constraints.removeLast() }
        // ISO BMFF codec strings reverse compatibility bits and separate constraint bytes with dots.
        return "hvc1.\(profile).\(String(reversed, radix: 16, uppercase: true)).\(data[1] & 32 == 0 ? "L" : "H")\(data[12])." +
            constraints.map { String(format: "%02X", $0) }.joined(separator: ".")
    }

    static func jocComplexity(at url: URL) async -> UInt8? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let description = try? await track.load(.formatDescriptions).first else { return nil }
        var size = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size), size > 0 else { return nil }
        return jocComplexity(in: Data(bytes: cookie, count: size))
    }

    static func jocComplexity(in cookie: Data) -> UInt8? {
        let box = Array(cookie)
        guard box.count >= 10, box[4..<8].elementsEqual("dec3".utf8) else { return nil }
        let size = box.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard size >= 10, size <= box.count else { return nil }
        var offset = 10
        for _ in 0...Int(box[9] & 7) {
            guard offset + 3 <= size else { return nil }
            // A dependent substream adds one byte to the independent substream entry.
            offset += (box[offset + 2] & 0x1e) == 0 ? 3 : 4
        }
        guard offset + 2 <= size, box[offset] & 1 != 0, box[offset + 1] > 0 else { return nil }
        return box[offset + 1]
    }
}
