import XCTest
@testable import BeamlyCore

final class PlaylistTests: XCTestCase {
    func testWatchHistorySurvivesQueueRemovalAndKeepsPerVideoCorrections() throws {
        var playlist = Playlist()
        let movie = URL(fileURLWithPath: "/tmp/Movie.mkv")
        playlist.append([movie])
        playlist.remember(position: 42, duration: 120)
        playlist.items[0].audioDelay = -0.4
        playlist.items[0].subtitleDelay = 1.5
        let date = Date(timeIntervalSince1970: 1_000)
        playlist.recordHistory(try XCTUnwrap(playlist.current), at: date)
        playlist.remove(try XCTUnwrap(playlist.currentID))
        playlist = try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(playlist))
        XCTAssertTrue(playlist.items.isEmpty)
        XCTAssertEqual(playlist.history?.first?.watchedAt, date)
        XCTAssertFalse(try XCTUnwrap(playlist.history?.first).isFinished)
        playlist.append([URL(fileURLWithPath: "/tmp/./Movie.mkv")])
        XCTAssertEqual(playlist.current?.position, 42)
        XCTAssertEqual(playlist.current?.audioDelay, -0.4)
        XCTAssertEqual(playlist.current?.subtitleDelay, 1.5)
        playlist.remember(position: 120, duration: 120)
        playlist.recordHistory(try XCTUnwrap(playlist.current))
        XCTAssertEqual(playlist.history?.count, 1)
        XCTAssertTrue(try XCTUnwrap(playlist.history?.first).isFinished)
        for index in 0..<105 {
            var item = PlaylistItem(url: URL(fileURLWithPath: "/tmp/\(index).mp4"))
            item.position = 5; item.duration = 100
            playlist.recordHistory(item)
        }
        XCTAssertEqual(playlist.history?.count, 100)
        XCTAssertEqual(playlist.history?.first?.video.title, "104")
        let history = playlist.history
        var invalid = PlaylistItem(url: movie)
        for value in [Double.nan, .infinity, -1] {
            invalid.position = value; invalid.duration = 100
            playlist.recordHistory(invalid)
        }
        XCTAssertEqual(playlist.history, history)
        playlist.history = []
        XCTAssertEqual(playlist.current?.position, 120, "Clearing history must preserve the active queue")
    }

    func testSubtitleFilesMatchOnlyReadableNeighboursAndPreferExactBasename() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Beamly-subtitles-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("Фильм Café.mkv")
        for name in ["Фильм Café.srt", "фильм cafe\u{301}.ru.SRT", "Фильм Café.en.forced.ass", "Фильм Café.fr.ssa", "Фильм Café.es.vtt",
                     "Фильм Café 2.srt", "Фильм Café-extra.srt", "Фильм Café.part2.mkv", "Фильм Café.part2.ru.srt", "Unrelated.srt", "Фильм Café.jpg", ".Фильм Café.srt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Фильм Café.de.srt"), withIntermediateDirectories: true)
        let matches = findSubtitleFiles(for: movie)
        XCTAssertEqual(matches.count, 5)
        XCTAssertEqual(matches.first?.lastPathComponent, "Фильм Café.srt")
        XCTAssertTrue(matches.contains { $0.lastPathComponent.hasSuffix(".ru.SRT") })
        XCTAssertTrue(findSubtitleFiles(for: folder.appendingPathComponent("Missing.mkv")).isEmpty)
        XCTAssertTrue(findSubtitleFiles(for: URL(string: "https://example.com/movie.mkv")!).isEmpty)
    }

    func testExistingQueuesDecodeAndKeepIndependentSubtitleCorrections() throws {
        var queue = Playlist()
        queue.append([URL(fileURLWithPath: "/tmp/first.mkv"), URL(fileURLWithPath: "/tmp/second.mp4")])
        queue.remember(position: 42, duration: 100)
        let legacy = try JSONEncoder().encode(queue)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("subtitleDelay"))
        var restored = try JSONDecoder().decode(Playlist.self, from: legacy)
        XCTAssertEqual(restored, queue)
        XCTAssertNil(restored.current?.subtitleDelay)
        restored.items[0].subtitleDelay = 1.5
        restored.items[1].subtitleDelay = -0.5
        let saved = try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(saved.items.map(\.subtitleDelay), [1.5, -0.5])
        XCTAssertEqual(saved.items[0].position, 42)
        XCTAssertEqual(saved.items[0].duration, 100)
    }

    func testQueueContinuityDeduplicationAndRepeat() throws {
        var queue = Playlist()
        let a = URL(fileURLWithPath: "/tmp/a.mp4")
        let b = URL(fileURLWithPath: "/tmp/b.mkv")
        queue.append([a, b, a, URL(string: "https://example.com/a.mp4")!])
        XCTAssertEqual(queue.items.count, 2)
        let first = try XCTUnwrap(queue.currentID)
        XCTAssertEqual(queue.next(), queue.items[1].id)
        queue.repeatMode = .one
        XCTAssertEqual(queue.next(finishing: true), first)
        XCTAssertNotEqual(queue.next(), first)
        queue.currentID = queue.items[1].id
        queue.repeatMode = .off
        XCTAssertNil(queue.next(finishing: true))
        queue.repeatMode = .all
        XCTAssertEqual(queue.next(finishing: true), first)
        queue.remove(queue.items[1].id)
        XCTAssertEqual(queue.currentID, first)
        queue.remember(position: .nan, duration: 90)
        XCTAssertEqual(queue.current?.position, 0)
        XCTAssertEqual(queue.current?.duration, 90)
        XCTAssertEqual(try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(queue)), queue)
    }

    func testTimeFormattingRejectsInvalidMediaTimes() {
        XCTAssertEqual(mediaTime(.infinity), "0:00")
        XCTAssertEqual(mediaTime(-1), "0:00")
        XCTAssertEqual(mediaTime(3661.8), "1:01:01")
    }

    func testShuffleVisitsEachItemOnceAndRepeatAllStartsAnotherCycle() throws {
        var queue = Playlist()
        queue.append(["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/\($0).mp4") })
        queue.shuffle = true
        var seen = Set([try XCTUnwrap(queue.currentID)])
        for _ in 0..<2 {
            let next = try XCTUnwrap(queue.next(finishing: true))
            XCTAssertTrue(seen.insert(next).inserted)
            queue.currentID = next
        }
        XCTAssertEqual(seen, Set(queue.items.map(\.id)))
        XCTAssertNil(queue.next(finishing: true))
        let last = try XCTUnwrap(queue.currentID)
        queue.currentID = try XCTUnwrap(queue.previous())
        XCTAssertEqual(queue.next(), last)
        queue.currentID = last
        queue.repeatMode = .one
        XCTAssertEqual(queue.next(finishing: true), last)
        queue.repeatMode = .all
        seen.removeAll()
        for _ in 0..<3 {
            let next = try XCTUnwrap(queue.next(finishing: true))
            XCTAssertTrue(seen.insert(next).inserted)
            queue.currentID = next
        }
        XCTAssertEqual(seen, Set(queue.items.map(\.id)))
        queue.repeatMode = .off
        XCTAssertNil(queue.next(finishing: true))
        XCTAssertEqual(try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(queue)), queue)
    }
}
