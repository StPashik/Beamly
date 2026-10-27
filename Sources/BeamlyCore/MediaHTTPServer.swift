import Foundation
import Network
import SystemConfiguration
import Darwin

/// A capability URL exposes only a deliberately published movie or HLS directory.
public final class MediaHTTPServer: @unchecked Sendable {
    // All mutable state is confined to queue, including Network.framework callbacks.
    private enum Publication {
        case file(URL, name: String)
        case directory(URL)
    }

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var header = Data()
        var timeout: DispatchWorkItem?
        var file: FileHandle?
        var remaining: UInt64 = 0

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "Beamly.media-http")
    private var listener: NWListener?
    private var starting: CheckedContinuation<Void, Error>?
    private var publications: [String: Publication] = [:]
    private var clients: [UUID: Client] = [:]
    private var token = UUID().uuidString.lowercased()
    private var listeningPort: UInt16 = 0
    private var advertisedHost = "127.0.0.1"

    public init() {}

    public var port: UInt16 { queue.sync { listeningPort } }
    public var host: String { queue.sync { advertisedHost } }

    public func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if self.listeningPort != 0 { continuation.resume(); return }
                guard self.starting == nil else {
                    continuation.resume(throwing: ServerError("The media server is already starting."))
                    return
                }
                do {
                    let listener = try NWListener(using: .tcp, on: .any)
                    self.listener = listener
                    self.starting = continuation
                    self.advertisedHost = Self.lanIPv4()
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, let listener, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            self.listeningPort = listener.port?.rawValue ?? 0
                            self.starting?.resume()
                            self.starting = nil
                        case .failed(let error):
                            self.starting?.resume(throwing: error)
                            self.starting = nil
                            self.shutdown()
                        default: break
                        }
                    }
                    listener.start(queue: self.queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func publish(file: URL) throws -> URL {
        try queue.sync {
            let file = file.standardizedFileURL.resolvingSymlinksInPath()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw ServerError("The selected movie is not a regular file.") }
            let ext = file.pathExtension.lowercased()
            let name = "media." + (ext.range(of: "^[a-z0-9]+$", options: .regularExpression) == nil ? "bin" : ext)
            return try register(.file(file, name: name), name: name)
        }
    }

    public func publish(directory: URL, playlist: String = "stream.m3u8") throws -> URL {
        try queue.sync {
            let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true, Self.isMediaName(playlist) else {
                throw ServerError("The HLS directory or playlist name is invalid.")
            }
            return try register(.directory(directory), name: playlist)
        }
    }

    public func revokeAll() {
        queue.sync {
            publications.removeAll()
            for id in Array(clients.keys) { finish(id) }
        }
    }

    public func stop() { queue.sync { shutdown() } }

    private func shutdown() {
        starting?.resume(throwing: CancellationError())
        starting = nil
        listener?.cancel()
        listener = nil
        listeningPort = 0
        publications.removeAll()
        token = UUID().uuidString.lowercased()
        for id in Array(clients.keys) { finish(id) }
    }

    private func register(_ publication: Publication, name: String) throws -> URL {
        guard listeningPort != 0 else { throw ServerError("The media server is not running.") }
        advertisedHost = Self.lanIPv4()
        // A fresh publication ID prevents an old URL from referring to a later movie.
        let id = UUID().uuidString.lowercased()
        publications[id] = publication
        var components = URLComponents()
        components.scheme = "http"
        components.host = advertisedHost
        components.port = Int(listeningPort)
        components.path = "/\(token)/\(id)/\(name)"
        guard let url = components.url else { throw ServerError("Cannot create a media URL.") }
        return url
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled: self.finish(client.id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func armTimeout(_ client: Client) {
        client.timeout?.cancel()
        let id = client.id
        let timeout = DispatchWorkItem { [weak self] in self?.finish(id) }
        client.timeout = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func receive(_ client: Client) {
        armTimeout(client)
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak client] data, _, complete, error in
            guard let self, let client, self.clients[client.id] != nil else { return }
            if let data { client.header.append(data) }
            guard client.header.count <= 16_384 else { self.respond(client, status: 431); return }
            if let end = client.header.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(client, header: client.header[..<end.lowerBound])
            } else if complete || error != nil {
                self.finish(client.id)
            } else { self.receive(client) }
        }
    }

    private func handle(_ client: Client, header: Data.SubSequence) {
        guard let text = String(data: Data(header), encoding: .utf8) else { respond(client, status: 400); return }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else {
            respond(client, status: 400); return
        }
        let method = String(request[0])
        guard method == "GET" || method == "HEAD" else {
            respond(client, status: 405, fields: ["Allow": "GET, HEAD"]); return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(client, status: 400); return }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { respond(client, status: 400); return }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let file = resolve(String(request[1])) else { respond(client, status: 404); return }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            client.file = handle
            let size = try handle.seekToEnd()
            var first: UInt64 = 0
            var length = size
            var status = 200
            var fields = ["Accept-Ranges": "bytes", "Content-Type": Self.mimeType(file), "Cache-Control": "no-store"]
            if let range = headers["range"] {
                guard let bytes = Self.byteRange(range, size: size) else {
                    respond(client, status: 416, fields: ["Content-Range": "bytes */\(size)"]); return
                }
                first = bytes.lowerBound
                length = bytes.upperBound - bytes.lowerBound + 1
                status = 206
                fields["Content-Range"] = "bytes \(first)-\(bytes.upperBound)/\(size)"
            }
            try handle.seek(toOffset: first)
            client.remaining = method == "HEAD" ? 0 : length
            fields["Content-Length"] = String(length)
            sendHeader(client, status: status, fields: fields) { [weak self, weak client] in
                guard let self, let client else { return }
                self.sendChunk(client)
            }
        } catch { respond(client, status: 404) }
    }

    private func resolve(_ target: String) -> URL? {
        guard target.hasPrefix("/"),
              let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.flatMap({ String($0).removingPercentEncoding }),
              !path.contains("\\"), !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == token,
              !parts[3].hasPrefix("."), !parts[3].hasSuffix(".tmp"),
              let publication = publications[String(parts[2])] else { return nil }
        let name = String(parts[3])
        let file: URL
        switch publication {
        case .file(let published, let expected):
            guard name == expected else { return nil }
            file = published
        case .directory(let directory):
            guard Self.isMediaName(name) else { return nil }
            file = directory.appendingPathComponent(name)
            // Resolve symlinks before confinement checks; .inputs must never be served.
            guard file.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.path else { return nil }
        }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return file
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

    private func respond(_ client: Client, status: Int, fields: [String: String] = [:]) {
        var fields = fields
        fields["Content-Length"] = "0"
        sendHeader(client, status: status, fields: fields) { [weak self] in self?.finish(client.id) }
    }

    private func sendHeader(_ client: Client, status: Int, fields: [String: String], completion: @escaping () -> Void) {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable", 431: "Request Header Fields Too Large"][status] ?? "Error"
        var text = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
        for (name, value) in fields { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        armTimeout(client)
        client.connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, self.clients[client.id] != nil else { return }
            if error != nil { self.finish(client.id) } else { completion() }
        })
    }

    private func sendChunk(_ client: Client) {
        // Read the next bounded chunk only after the previous network send completes.
        guard clients[client.id] != nil else { return }
        guard client.remaining > 0 else { finish(client.id); return }
        do {
            guard let chunk = try client.file?.read(upToCount: Int(min(client.remaining, 256 * 1024))), !chunk.isEmpty else {
                finish(client.id); return
            }
            client.remaining -= UInt64(chunk.count)
            armTimeout(client)
            client.connection.send(content: chunk, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client, self.clients[client.id] != nil else { return }
                if error != nil { self.finish(client.id) } else { self.sendChunk(client) }
            })
        } catch { finish(client.id) }
    }

    private func finish(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timeout?.cancel()
        try? client.file?.close()
        client.file = nil
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
    }

    private static func isMediaName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return ["m3u8", "ts", "m4s", "mp4", "m4v", "mov", "vtt", "aac"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    private static func mimeType(_ file: URL) -> String {
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

    private static func lanIPv4() -> String {
        let store = SCDynamicStoreCreate(nil, "Beamly" as CFString, nil, nil)
        let state = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let primary = state?["PrimaryInterface"] as? String
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return "127.0.0.1" }
        defer { freeifaddrs(list) }
        var candidates: [(String, String)] = []
        var current = list
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { candidates.append((String(cString: interface.pointee.ifa_name), ip)) }
            }
        }
        if let primary, let match = candidates.first(where: { $0.0 == primary }) { return match.1 }
        return candidates.first(where: { $0.0.hasPrefix("en") })?.1 ?? candidates.first?.1 ?? "127.0.0.1"
    }
}

private struct ServerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { NSLocalizedString(message, comment: "") }
}
