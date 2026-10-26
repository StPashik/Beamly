import XCTest
@testable import BeamlyCore

final class MediaHTTPServerTests: XCTestCase {
    func testByteRangeBoundaries() {
        XCTAssertEqual(MediaHTTPServer.byteRange("bytes=2-4", size: 10), 2...4)
        XCTAssertEqual(MediaHTTPServer.byteRange("bytes=7-", size: 10), 7...9)
        XCTAssertEqual(MediaHTTPServer.byteRange("bytes=-3", size: 10), 7...9)
        XCTAssertEqual(MediaHTTPServer.byteRange("bytes=-100", size: 10), 0...9)
        XCTAssertEqual(MediaHTTPServer.byteRange("bytes=8-100", size: 10), 8...9)
        for range in ["bytes=10-", "bytes=5-2", "bytes=-0", "bytes=-", "bytes=1-2,4-5", "bytes=+1-2", "items=1-2", "bytes=18446744073709551616-"] {
            XCTAssertNil(MediaHTTPServer.byteRange(range, size: 10), range)
        }
        XCTAssertNil(MediaHTTPServer.byteRange("bytes=0-", size: 0))
    }

    func testPublishedMovieHTTPContract() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("example.mp4")
        let payload = Data((0..<256).map(UInt8.init)) + Data(repeating: 42, count: 600_000)
        try payload.write(to: movie)
        let server = MediaHTTPServer()
        try await server.start()
        defer { server.stop() }
        let published = try server.publish(file: movie)
        let url = try loopback(published)
        let (all, response) = try await request(url)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(all, payload)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), String(payload.count))
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")

        let (head, headResponse) = try await request(url, method: "HEAD")
        XCTAssertEqual(headResponse.statusCode, 200)
        XCTAssertTrue(head.isEmpty)
        XCTAssertEqual(headResponse.value(forHTTPHeaderField: "Content-Length"), String(payload.count))

        let (part, partialResponse) = try await request(url, range: "bytes=20-35")
        XCTAssertEqual(partialResponse.statusCode, 206)
        XCTAssertEqual(part, payload[20...35])
        XCTAssertEqual(partialResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 20-35/\(payload.count)")
        let (suffix, suffixResponse) = try await request(url, range: "bytes=-8")
        XCTAssertEqual(suffixResponse.statusCode, 206)
        XCTAssertEqual(suffix, payload.suffix(8))
        let (tail, tailResponse) = try await request(url, range: "bytes=600250-")
        XCTAssertEqual(tailResponse.statusCode, 206)
        XCTAssertEqual(tail, payload.suffix(6))

        let (_, unsatisfied) = try await request(url, range: "bytes=999999-")
        XCTAssertEqual(unsatisfied.statusCode, 416)
        XCTAssertEqual(unsatisfied.value(forHTTPHeaderField: "Content-Range"), "bytes */\(payload.count)")
        let (_, post) = try await request(url, method: "POST")
        XCTAssertEqual(post.statusCode, 405)
        XCTAssertEqual(post.value(forHTTPHeaderField: "Allow"), "GET, HEAD")

        var wrongToken = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let components = url.path.split(separator: "/").map(String.init)
        wrongToken.path = "/wrong/\(components[1])/\(components[2])"
        let (_, forbidden) = try await request(try XCTUnwrap(wrongToken.url))
        XCTAssertEqual(forbidden.statusCode, 404)
        server.revokeAll()
        let (_, revoked) = try await request(url)
        XCTAssertEqual(revoked.statusCode, 404)
    }

    func testHLSDirectoryIsConfinedAndEmptyFilesHaveNoRange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlist = Data("#EXTM3U\n#EXTINF:2,\nsegment_00000.ts\n".utf8)
        try playlist.write(to: directory.appendingPathComponent("stream.m3u8"))
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("segment_00000.ts"))
        try Data().write(to: directory.appendingPathComponent("empty.ts"))
        try Data("private".utf8).write(to: directory.appendingPathComponent("transcode.log"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.ts"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let inputs = directory.appendingPathComponent(".inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try Data([4]).write(to: inputs.appendingPathComponent("private.ts"))
        let server = MediaHTTPServer()
        try await server.start()
        defer { server.stop() }
        let url = try loopback(server.publish(directory: directory))
        let (body, response) = try await request(url)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(body, playlist)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/vnd.apple.mpegurl")
        let base = url.deletingLastPathComponent()
        for path in ["missing.ts", "escape.ts", "transcode.log", ".inputs/private.ts", "segment_00000.ts.tmp", "../stream.m3u8"] {
            let (_, blocked) = try await request(base.appendingPathComponent(path))
            XCTAssertEqual(blocked.statusCode, 404, path)
        }
        var encodedTraversal = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        encodedTraversal.percentEncodedPath = base.path + "/%2e%2e%2fstream.m3u8"
        let (_, encodedEscape) = try await request(try XCTUnwrap(encodedTraversal.url))
        XCTAssertEqual(encodedEscape.statusCode, 404)
        let (_, segment) = try await request(base.appendingPathComponent("segment_00000.ts"))
        XCTAssertEqual(segment.statusCode, 200)
        let (emptyBody, empty) = try await request(base.appendingPathComponent("empty.ts"))
        XCTAssertEqual(empty.statusCode, 200)
        XCTAssertTrue(emptyBody.isEmpty)
        XCTAssertEqual(empty.value(forHTTPHeaderField: "Content-Length"), "0")
        let (_, emptyRange) = try await request(base.appendingPathComponent("empty.ts"), range: "bytes=0-")
        XCTAssertEqual(emptyRange.statusCode, 416)
    }

    private func loopback(_ url: URL) throws -> URL {
        var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.host = "127.0.0.1"
        return try XCTUnwrap(components.url)
    }

    private func request(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = method
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (body, response) = try await URLSession.shared.data(for: request)
        return (body, try XCTUnwrap(response as? HTTPURLResponse))
    }
}
