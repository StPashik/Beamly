import AppKit
import BeamlyCore
import XCTest
@testable import Beamly

final class PreviewTests: XCTestCase {
    @MainActor
    func testMidpointImageForMP4AndMKVDoesNotLoadOrMoveThePlayer() async throws {
        let tools = FFmpegTools()
        guard let ffmpeg = tools.ffmpegURL, tools.ffprobeURL != nil else { throw XCTSkip("FFmpeg is not installed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-preview-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mp4 = folder.appendingPathComponent("Red then blue.mp4")
        let mkv = folder.appendingPathComponent("Red then blue.mkv")
        let process = Process()
        process.executableURL = ffmpeg
        // The first frame is red; the midpoint at three seconds must be blue.
        process.arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=red:s=160x90:r=10:d=2",
                             "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=10:d=4", "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
                             "-map", "[v]", "-c:v", "libx264", "-g", "10", "-pix_fmt", "yuv420p", mp4.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let remux = Process()
        remux.executableURL = ffmpeg
        remux.arguments = ["-v", "error", "-nostdin", "-y", "-i", mp4.path, "-c", "copy", mkv.path]
        remux.standardInput = FileHandle.nullDevice
        remux.standardOutput = FileHandle.nullDevice
        remux.standardError = FileHandle.nullDevice
        try remux.run()
        remux.waitUntilExit()
        XCTAssertEqual(remux.terminationStatus, 0)

        for invalid in [-1, Double.infinity, Double.nan] {
            do {
                _ = try await tools.thumbnail(url: mp4, at: invalid)
                XCTFail("Invalid thumbnail time was accepted")
            } catch MediaPipelineError.invalidMedia { }
        }

        let png = try await tools.thumbnail(url: mkv, at: 3)
        try assertBlue(try XCTUnwrap(NSImage(data: png)))
        for movie in [mp4, mkv] {
            let name = "app.beamly.preview-tests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            var saved = Playlist()
            saved.append([movie])
            saved.items[0].duration = 6
            let state = folder.appendingPathComponent("queue-\(movie.pathExtension).json")
            try JSONEncoder().encode(saved).write(to: state)
            let model = AppModel(stateURL: state, defaults: defaults)
            defer { model.shutdown(); defaults.removePersistentDomain(forName: name) }
            let deadline = Date().addingTimeInterval(15)
            while model.previewImage == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            let image = try XCTUnwrap(model.previewImage, movie.pathExtension)
            try assertBlue(image)
            XCTAssertNil(model.player.currentItem)
            XCTAssertEqual(model.player.rate, 0)
            XCTAssertEqual(model.position, 0)
            model.seek(1)
            XCTAssertTrue(model.previewImage === image)
            model.clear()
            XCTAssertNil(model.previewImage)
        }
    }

    private func assertBlue(_ image: NSImage, file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), file: file, line: line)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB), file: file, line: line)
        XCTAssertGreaterThan(color.blueComponent, 0.8, file: file, line: line)
        XCTAssertLessThan(color.redComponent, 0.2, file: file, line: line)
        XCTAssertLessThanOrEqual(bitmap.pixelsWide, 288)
        XCTAssertLessThanOrEqual(bitmap.pixelsHigh, 162)
    }
}
