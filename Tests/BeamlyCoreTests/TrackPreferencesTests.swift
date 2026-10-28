import XCTest
@testable import BeamlyCore

final class TrackPreferencesTests: XCTestCase {
    func testLanguageCodesIncludeAliasesAndRegionsWithoutGuessingUnknownTags() {
        for value in ["rus", "ru-RU", "RU"] { XCTAssertEqual(MediaLanguages.normalized(value), "ru", value) }
        for value in ["ger", "deu", "de-DE"] { XCTAssertEqual(MediaLanguages.normalized(value), "de", value) }
        for value in ["fre", "fra", "fr-CA"] { XCTAssertEqual(MediaLanguages.normalized(value), "fr", value) }
        XCTAssertEqual(MediaLanguages.normalized("eng"), "en")
        for value in [nil, "und", "zxx", "invalid", ""] { XCTAssertNil(MediaLanguages.normalized(value), value ?? "nil") }
        XCTAssertEqual(Set(MediaLanguages.codes).count, MediaLanguages.codes.count)
        XCTAssertTrue(MediaLanguages.codes.allSatisfy { $0.count == 2 })
    }

    func testAudioPrefersMainLanguageOrExplicitOriginalAndFallsBackToFileDefault() {
        let tracks = [
            MediaTrack(id: 2, codec: "aac", language: "eng", disposition: ["original": 1]),
            MediaTrack(id: 4, codec: "aac", language: "rus", disposition: ["comment": 1]),
            MediaTrack(id: 7, codec: "aac", language: "ru-RU"),
            MediaTrack(id: 9, codec: "aac", language: "rus", disposition: ["default": 1])
        ]
        XCTAssertEqual(TrackPreferences(audio: "ru").audioTrack(in: tracks), 9)
        XCTAssertEqual(TrackPreferences(audio: "original").audioTrack(in: tracks), 2)
        XCTAssertNil(TrackPreferences(audio: "es").audioTrack(in: tracks))
        XCTAssertNil(TrackPreferences().audioTrack(in: tracks))
        XCTAssertNil(TrackPreferences(audio: "ru").audioTrack(in: [tracks[1]]), "Do not select commentary as the preferred language")
        XCTAssertNil(TrackPreferences(audio: "original").audioTrack(in: Array(tracks.dropFirst())), "Do not infer original from order or language")
        let info = MediaInfo(duration: 1, width: 160, height: 90, videoCodec: "h264", audioTracks: tracks)
        XCTAssertEqual(info.defaultAudioTrack?.id, 9)
        XCTAssertEqual(TrackPreferences(audio: "invalid", subtitles: "invalid").audio, "default")
        XCTAssertEqual(TrackPreferences(audio: "invalid", subtitles: "invalid").subtitles, "automatic")
    }

    func testAutomaticAndOffRetainExistingSidecarRules() {
        let video = URL(fileURLWithPath: "/tmp/Movie.mkv")
        let plain = URL(fileURLWithPath: "/tmp/Movie.srt")
        let russian = URL(fileURLWithPath: "/tmp/Movie.ru.srt")
        let english = URL(fileURLWithPath: "/tmp/Movie.en.srt")
        let automatic = TrackPreferences()
        XCTAssertEqual(automatic.subtitleChoice(in: [], files: [english, plain, russian], video: video), .external(plain))
        XCTAssertEqual(automatic.subtitleChoice(in: [], files: [russian], video: video), .external(russian))
        XCTAssertEqual(automatic.subtitleChoice(in: [], files: [russian, english], video: video), .none)
        XCTAssertEqual(TrackPreferences(subtitles: "off").subtitleChoice(in: [MediaTrack(id: 4, codec: "subrip", disposition: ["default": 1])], files: [plain], video: video), .none)
    }

    func testSubtitleLanguageMatchesMetadataAndSidecarsPreferringFullCaptions() {
        let video = URL(fileURLWithPath: "/tmp/Movie.mkv")
        let plain = URL(fileURLWithPath: "/tmp/Movie.srt")
        let russian = URL(fileURLWithPath: "/tmp/Movie.ru-RU.srt")
        let forced = URL(fileURLWithPath: "/tmp/Movie.rus.forced.srt")
        let tracks = [MediaTrack(id: 3, codec: "subrip", language: "rus", disposition: ["forced": 1]),
                      MediaTrack(id: 5, codec: "subrip", language: "ru"),
                      MediaTrack(id: 7, codec: "subrip", language: "rus", disposition: ["default": 1])]
        let preferences = TrackPreferences(subtitles: "ru")
        XCTAssertEqual(preferences.subtitleChoice(in: tracks, files: [plain, forced], video: video), .embedded(7))
        XCTAssertEqual(preferences.subtitleChoice(in: tracks, files: [forced, russian], video: video), .external(russian))
        XCTAssertEqual(preferences.subtitleChoice(in: [tracks[0]], files: [forced], video: video), .external(forced))
        XCTAssertEqual(preferences.subtitleChoice(in: [tracks[0]], files: [], video: video), .embedded(3))
        XCTAssertEqual(preferences.subtitleChoice(in: [], files: [plain], video: video), .none)
        XCTAssertEqual(TrackPreferences(subtitles: "es").subtitleChoice(in: tracks, files: [russian], video: video), .none)
    }

    @MainActor
    func testProbeDispositionsAndCompatibilityDefaultAudioUseGlobalStreamID() throws {
        let data = Data(#"{"streams":[{"index":0,"codec_type":"video","codec_name":"h264"},{"index":2,"codec_type":"audio","codec_name":"aac","disposition":{"original":1}},{"index":5,"codec_type":"audio","codec_name":"aac","disposition":{"default":1,"comment":1}},{"index":8,"codec_type":"subtitle","codec_name":"subrip","disposition":{"forced":1}}]}"#.utf8)
        let info = try FFmpegTools.decodeProbe(data)
        XCTAssertTrue(info.audioTracks[0].isOriginal)
        XCTAssertTrue(info.audioTracks[1].isDefault)
        XCTAssertTrue(info.audioTracks[1].isCommentary)
        XCTAssertTrue(info.subtitleTracks[0].isForced)
        let arguments = HLSJob.arguments(input: URL(fileURLWithPath: "/tmp/Movie.mkv"), info: info, audioTrack: nil,
                                         subtitleRendering: nil, startTime: 0, hardwareEncoding: false)
        XCTAssertTrue(arguments.contains("0:5"))
        XCTAssertFalse(arguments.contains("0:2"))
        let legacy = try JSONDecoder().decode(MediaTrack.self, from: Data(#"{"id":2,"codec":"aac","language":"rus"}"#.utf8))
        XCTAssertNil(legacy.disposition)
    }
}
