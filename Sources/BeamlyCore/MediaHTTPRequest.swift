import Foundation

enum MediaHTTPRequest {
    case invalid
    case unsupportedMethod
    case request(method: String, target: String, range: String?)

    static func parse(_ header: Data.SubSequence) -> Self {
        guard let text = String(data: Data(header), encoding: .utf8) else { return .invalid }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else {
            return .invalid
        }
        let method = String(request[0])
        guard method == "GET" || method == "HEAD" else {
            return .unsupportedMethod
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { return .invalid }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return .request(method: method, target: String(request[1]), range: headers["range"])
    }

    static func byteRange(_ value: String, size: UInt64) -> ClosedRange<UInt64>? {
        guard value.hasPrefix("bytes="), size > 0 else { return nil }
        let values = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard values.count == 2 else { return nil }
        func number(_ text: Substring) -> UInt64? {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return UInt64(text)
        }
        if values[0].isEmpty {
            guard let suffix = number(values[1]), suffix > 0 else { return nil }
            return (size - min(suffix, size))...(size - 1)
        }
        guard let first = number(values[0]), first < size else { return nil }
        let last: UInt64
        if values[1].isEmpty { last = size - 1 }
        else {
            guard let requested = number(values[1]), requested >= first else { return nil }
            last = min(requested, size - 1)
        }
        return first...last
    }

    static func isMediaName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return ["m3u8", "ts", "m4s", "mp4", "m4v", "mov", "vtt", "aac"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    static func mimeType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4s": return "video/iso.segment"
        case "vtt": return "text/vtt; charset=utf-8"
        case "aac": return "audio/aac"
        default: return "application/octet-stream"
        }
    }
}
