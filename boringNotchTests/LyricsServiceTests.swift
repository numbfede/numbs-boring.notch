//
//  LyricsServiceTests.swift
//  boringNotchTests
//

import XCTest

@testable import boringNotch

final class LRCParserTests: XCTestCase {
    func testRepeatedTimestampsProduceOneLineEach() {
        let lines = LRCParser.parse("[00:42.00][00:10.50]Chorus")
        XCTAssertEqual(lines.map { $0.time }, [10.5, 42])
        XCTAssertEqual(lines.map { $0.text }, ["Chorus", "Chorus"])
    }

    func testFractionsUseTheirDigitCount() {
        let times = LRCParser.parse("[00:01.5]a\n[00:02.50]b\n[00:03.500]c").map { $0.time }
        XCTAssertEqual(times, [1.5, 2.5, 3.5])
    }

    func testGapsAreKeptWithoutRepeatedBlanks() {
        let lines = LRCParser.parse("[00:00.00]\n[00:01.00]a\n[00:02.00]\n[00:03.00]\n[00:04.00]b")
        XCTAssertEqual(lines.map { $0.text }, ["a", "", "b"])
    }

    func testOffsetAndMetadata() {
        let lines = LRCParser.parse("[ar:Someone]\n[offset:+500]\n[00:02.00]a")
        XCTAssertEqual(lines.first?.time, 1.5)
        XCTAssertEqual(lines.count, 1)
    }

    func testTextWithoutLyricsIsEmpty() {
        XCTAssertTrue(LRCParser.parse("[00:01.00]\n[00:02.00]").isEmpty)
    }
}

final class LyricsMatchingTests: XCTestCase {
    func testTitleAndArtistCleanup() {
        XCTAssertEqual(LyricsMatching.strippedTitle("Song (Remastered 2011)"), "Song")
        XCTAssertEqual(LyricsMatching.strippedTitle("Song - Live at Wembley"), "Song")
        XCTAssertEqual(LyricsMatching.strippedTitle("Song feat. Someone"), "Song")
        XCTAssertEqual(LyricsMatching.strippedTitle("Part (One)"), "Part (One)")
        XCTAssertEqual(LyricsMatching.primaryArtist("Someone - Topic"), "Someone")
        XCTAssertEqual(LyricsMatching.primaryArtist("A, B & C"), "A")
    }

    func testSearchURLEncodesReservedCharacters() throws {
        let url = try XCTUnwrap(LyricsMatching.searchURL(for: .init(title: "Rock & Roll + More", artist: nil)))
        XCTAssertTrue(url.absoluteString.contains("Rock%20%26%20Roll%20%2B%20More"), url.absoluteString)
    }

    func testRejectsSameTitleByAnotherArtist() {
        let results: [[String: Any]] = [["trackName": "Hello", "artistName": "Someone Else", "plainLyrics": "x"]]
        XCTAssertNil(LyricsMatching.bestMatch(in: results, title: "Hello", artist: "Adele", duration: nil))
    }

    func testPrefersMatchingDuration() {
        let results: [[String: Any]] = [
            ["trackName": "Hello", "artistName": "Adele", "plainLyrics": "x", "syncedLyrics": "y", "duration": 400.0, "id": 1],
            ["trackName": "Hello", "artistName": "Adele", "plainLyrics": "x", "syncedLyrics": "y", "duration": 295.0, "id": 2],
        ]
        let best = LyricsMatching.bestMatch(in: results, title: "Hello", artist: "Adele", duration: 295)
        XCTAssertEqual(best?["id"] as? Int, 2)
    }

    func testIgnoresInstrumentalResults() {
        let results: [[String: Any]] = [["trackName": "Song", "artistName": "A", "instrumental": true, "plainLyrics": "x"]]
        XCTAssertNil(LyricsMatching.bestMatch(in: results, title: "Song", artist: "A", duration: nil))
    }
}
