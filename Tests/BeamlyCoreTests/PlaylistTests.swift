import XCTest
@testable import BeamlyCore

final class PlaylistTests: XCTestCase {
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
