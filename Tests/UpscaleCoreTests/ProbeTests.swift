import XCTest
@testable import UpscaleCore

final class ProbeParsingTests: XCTestCase {
    /// ffprobe mixes numbers and strings for numeric fields, and Matroska omits
    /// `nb_frames` and the per-stream duration entirely.
    func testParsesMatroskaShapedOutput() throws {
        let json = """
        {
          "streams": [
            {
              "index": 0, "codec_name": "h264", "codec_type": "video",
              "width": 1920, "height": 1080, "pix_fmt": "yuv420p",
              "r_frame_rate": "24000/1001", "avg_frame_rate": "24000/1001",
              "sample_aspect_ratio": "1:1", "color_range": "tv", "color_space": "bt709",
              "color_primaries": "bt709", "color_transfer": "bt709",
              "tags": {"language": "und"}
            },
            {
              "index": 1, "codec_name": "aac", "codec_type": "audio", "channels": 2,
              "tags": {"language": "jpn", "title": "Japanese"},
              "disposition": {"default": 1}
            },
            {
              "index": 2, "codec_name": "subrip", "codec_type": "subtitle",
              "tags": {"LANGUAGE": "eng"}
            },
            {
              "index": 3, "codec_name": "ttf", "codec_type": "attachment",
              "tags": {"filename": "font.ttf"}
            }
          ],
          "format": {
            "filename": "sample.mkv", "format_name": "matroska,webm", "duration": "23.500"
          }
        }
        """.data(using: .utf8)!

        let info = try Probe.parse(json: json, path: "sample.mkv")

        XCTAssertEqual(info.formatName, "matroska,webm")
        XCTAssertEqual(info.duration, 23.5)
        XCTAssertEqual(info.video.codec, "h264")
        XCTAssertEqual(info.video.width, 1920)
        XCTAssertEqual(info.video.height, 1080)
        XCTAssertEqual(info.video.bitDepth, 8)
        XCTAssertEqual(info.video.realFrameRate, Rational(24000, 1001))
        XCTAssertEqual(info.video.sampleAspectRatio, Rational(1, 1))
        XCTAssertFalse(info.video.isAnamorphic)
        XCTAssertEqual(info.audioStreams.count, 1)
        XCTAssertEqual(info.audioStreams[0].language, "jpn")
        XCTAssertEqual(info.audioStreams[0].channels, 2)
        XCTAssertTrue(info.audioStreams[0].isDefault)
        XCTAssertEqual(info.subtitleStreams.count, 1)
        // Tag lookup has to be case-insensitive: Matroska writes LANGUAGE here.
        XCTAssertEqual(info.subtitleStreams[0].language, "eng")
        XCTAssertEqual(info.attachmentStreams.count, 1)
        // No nb_frames in the container, so the count comes from duration x rate.
        XCTAssertEqual(info.estimatedFrameCount, 563)
        XCTAssertNil(info.rejectionReason())
    }

    func testStringNumbersAndNotAvailableFields() throws {
        let json = """
        {
          "streams": [{
            "index": 0, "codec_name": "hevc", "codec_type": "video",
            "width": 1280, "height": 720, "pix_fmt": "yuv420p10le",
            "bits_per_raw_sample": "10", "r_frame_rate": "25/1",
            "avg_frame_rate": "0/0", "nb_frames": "250", "duration": "10.000",
            "sample_aspect_ratio": "0:1", "color_transfer": "smpte2084",
            "color_primaries": "bt2020"
          }],
          "format": {"format_name": "mov,mp4,m4a", "duration": "N/A"}
        }
        """.data(using: .utf8)!

        let info = try Probe.parse(json: json, path: "hdr.mp4")
        XCTAssertEqual(info.video.bitDepth, 10)
        XCTAssertEqual(info.video.nominalFrameCount, 250)
        XCTAssertNil(info.duration)
        // "0:1" means unknown, which is square pixels in practice.
        XCTAssertEqual(info.video.sampleAspectRatio, Rational.one)
        XCTAssertEqual(info.estimatedFrameCount, 250)

        // 10-bit is processed now; this file is refused for being HDR, not for its depth.
        let reason = try XCTUnwrap(info.rejectionReason())
        XCTAssertTrue(reason.contains("smpte2084"), reason)
    }

    /// 12-bit has no plane format on the pipes, so it is still refused.
    func testTwelveBitIsRefused() throws {
        let json = """
        {
          "streams": [{
            "index": 0, "codec_name": "hevc", "codec_type": "video",
            "width": 1280, "height": 720, "pix_fmt": "yuv420p12le",
            "bits_per_raw_sample": "12", "r_frame_rate": "25/1",
            "avg_frame_rate": "25/1"
          }],
          "format": {"format_name": "matroska,webm", "duration": "10.000"}
        }
        """.data(using: .utf8)!

        let info = try Probe.parse(json: json, path: "twelve.mkv")
        XCTAssertEqual(info.video.bitDepth, 12)
        let reason = try XCTUnwrap(info.rejectionReason())
        XCTAssertTrue(reason.contains("12-bit"), reason)
    }

    /// Plain 10-bit SDR passes the gate.
    func testTenBitSDRIsAccepted() throws {
        let json = """
        {
          "streams": [{
            "index": 0, "codec_name": "hevc", "codec_type": "video",
            "width": 1920, "height": 1080, "pix_fmt": "yuv420p10le",
            "bits_per_raw_sample": "10", "r_frame_rate": "24000/1001",
            "avg_frame_rate": "24000/1001", "color_space": "bt709",
            "color_primaries": "bt709", "color_transfer": "bt709"
          }],
          "format": {"format_name": "matroska,webm", "duration": "1420.0"}
        }
        """.data(using: .utf8)!

        let info = try Probe.parse(json: json, path: "anime.mkv")
        XCTAssertEqual(info.video.bitDepth, 10)
        XCTAssertNil(info.rejectionReason())
    }

    func testAnamorphicDetection() throws {
        let json = """
        {"streams": [{"index": 0, "codec_type": "video", "codec_name": "mpeg2video",
          "width": 720, "height": 576, "pix_fmt": "yuv420p", "r_frame_rate": "25/1",
          "sample_aspect_ratio": "64:45"}], "format": {"format_name": "mpegts"}}
        """.data(using: .utf8)!
        let info = try Probe.parse(json: json, path: "dvd.ts")
        XCTAssertTrue(info.video.isAnamorphic)
        XCTAssertEqual(info.video.sampleAspectRatio, Rational(64, 45))
    }

    func testFileWithoutVideoStreamIsRejected() {
        let json = """
        {"streams": [{"index": 0, "codec_type": "audio", "codec_name": "flac"}],
         "format": {"format_name": "flac"}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try Probe.parse(json: json, path: "song.flac")) { error in
            guard case UpscaleError.noVideoStream = error else {
                return XCTFail("expected noVideoStream, got \(error)")
            }
        }
    }

    func testChaptersAreDecoded() throws {
        let json = """
        {
          "streams": [{
            "index": 0, "codec_name": "h264", "codec_type": "video",
            "width": 640, "height": 480, "pix_fmt": "yuv420p",
            "r_frame_rate": "25/1", "avg_frame_rate": "25/1"
          }],
          "chapters": [
            {
              "id": 0, "time_base": "1/1000", "start": 0, "start_time": "0.000000",
              "end": 3000, "end_time": "3.000000", "tags": {"title": "OP"}
            },
            {
              "id": 1, "time_base": "1/1000", "start": 3000, "start_time": "3.000000",
              "end": 10000, "end_time": "10.000000", "tags": {"title": "Part A"}
            }
          ],
          "format": {"format_name": "matroska,webm", "duration": "10.000"}
        }
        """.data(using: .utf8)!

        let info = try Probe.parse(json: json, path: "chapters.mkv")
        XCTAssertEqual(
            info.chapters,
            [
                Chapter(start: 0, end: 3, title: "OP"),
                Chapter(start: 3, end: 10, title: "Part A"),
            ]
        )
        XCTAssertEqual(
            ChapterSkipDetector.skippableRanges(in: info),
            [SkipRange(start: 0, end: 3, label: "OP")]
        )
    }

    /// Every file that has no chapters has to parse just as before.
    func testMissingChaptersKeyIsNotAnError() throws {
        let json = """
        {
          "streams": [{
            "index": 0, "codec_name": "h264", "codec_type": "video",
            "width": 640, "height": 480, "pix_fmt": "yuv420p",
            "r_frame_rate": "25/1", "avg_frame_rate": "25/1"
          }],
          "format": {"format_name": "matroska,webm", "duration": "10.000"}
        }
        """.data(using: .utf8)!
        XCTAssertEqual(try Probe.parse(json: json, path: "plain.mkv").chapters, [])
    }

    func testMalformedJSONIsReported() {
        XCTAssertThrowsError(try Probe.parse(json: Data("not json".utf8), path: "x")) { error in
            guard case UpscaleError.probeFailed = error else {
                return XCTFail("expected probeFailed, got \(error)")
            }
        }
    }
}

final class ProbeIntegrationTests: XCTestCase {
    func testProbesGeneratedMatroskaFixture() throws {
        let tools = try TestSupport.requireTools()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try TestSupport.makeFixture(in: directory)
        let info = try Probe(tools: tools).probe(url: fixture)

        XCTAssertTrue(info.formatName.contains("matroska"), info.formatName)
        XCTAssertEqual(info.video.codec, "h264")
        XCTAssertEqual(info.video.width, 320)
        XCTAssertEqual(info.video.height, 240)
        XCTAssertEqual(info.video.pixelFormat, "yuv420p")
        XCTAssertEqual(info.video.bitDepth, 8)
        XCTAssertEqual(info.video.realFrameRate, Rational(24000, 1001))
        XCTAssertEqual(info.audioStreams.count, 1)
        XCTAssertEqual(info.audioStreams[0].codec, "aac")
        XCTAssertEqual(info.subtitleStreams.count, 1)
        XCTAssertEqual(info.subtitleStreams[0].codec, "subrip")
        XCTAssertEqual(info.subtitleStreams[0].language, "eng")
        XCTAssertNil(info.rejectionReason())

        let frames = try XCTUnwrap(info.estimatedFrameCount)
        XCTAssertEqual(frames, 48, accuracy: 1)
    }

    func testProbeOfMissingFileFails() throws {
        let tools = try TestSupport.requireTools()
        let missing = URL(fileURLWithPath: "/tmp/upscale-does-not-exist.mkv")
        XCTAssertThrowsError(try Probe(tools: tools).probe(url: missing)) { error in
            guard case let UpscaleError.processFailed(tool, _, _) = error else {
                return XCTFail("expected processFailed, got \(error)")
            }
            XCTAssertEqual(tool, "ffprobe")
        }
    }
}
