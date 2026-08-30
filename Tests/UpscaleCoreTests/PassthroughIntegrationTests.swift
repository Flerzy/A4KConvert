import XCTest
@testable import UpscaleCore

/// WP1 acceptance: decode a fixture to raw frames and pipe them straight back into an
/// encode process with no processing in between, then verify the output survived the
/// round trip intact.
final class PassthroughIntegrationTests: XCTestCase {
    func testDecodeToEncodePassthroughPreservesStreamsAndDuration() throws {
        let tools = try TestSupport.requireTools()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try TestSupport.makeFixture(in: directory)
        let probe = Probe(tools: tools)
        let source = try probe.probe(url: fixture)
        let output = directory.appendingPathComponent("passthrough.mkv")

        let decode = DecodeProcess(ffmpeg: tools.ffmpeg, input: fixture, media: source)
        let plan = EncodePlan.make(
            for: source,
            scale: 1,
            settings: EncoderSettings(encoder: .hevc, quality: 70),
            container: .matroska
        )
        let encode = EncodeProcess(
            ffmpeg: tools.ffmpeg,
            source: fixture,
            media: source,
            output: output,
            plan: plan
        )

        var lastProgress = FFmpegProgress()
        encode.onProgress = { lastProgress = $0 }

        try decode.start()
        try encode.start()

        let reader = FrameReader(
            handle: try XCTUnwrap(decode.outputHandle),
            frameByteCount: decode.frameByteCount
        )
        let writer = FrameWriter(handle: try XCTUnwrap(encode.inputHandle))

        while let frame = try reader.readFrame() {
            try writer.write(frame: frame)
        }
        writer.finish()
        reader.close()

        try decode.waitAndCheck()
        try encode.waitAndCheck()

        XCTAssertEqual(reader.framesRead, writer.framesWritten)
        XCTAssertGreaterThan(reader.framesRead, 0)
        XCTAssertTrue(lastProgress.isFinished, "encode should have reported progress=end")
        XCTAssertEqual(lastProgress.frame, writer.framesWritten)

        let result = try probe.probe(url: output)
        XCTAssertEqual(result.video.width, source.video.width)
        XCTAssertEqual(result.video.height, source.video.height)
        XCTAssertEqual(result.video.codec, "hevc")
        XCTAssertEqual(result.video.realFrameRate, source.video.realFrameRate)
        XCTAssertEqual(result.audioStreams.count, 1)
        XCTAssertEqual(result.audioStreams[0].codec, "aac")
        XCTAssertEqual(result.subtitleStreams.count, 1)
        XCTAssertEqual(result.subtitleStreams[0].codec, "subrip")
        XCTAssertEqual(result.subtitleStreams[0].language, "eng")

        // Duration must match within one frame.
        let frameDuration = 1.0 / source.video.realFrameRate.doubleValue
        let sourceDuration = try XCTUnwrap(source.duration)
        let outputDuration = try XCTUnwrap(result.duration)
        XCTAssertEqual(outputDuration, sourceDuration, accuracy: frameDuration * 1.5)

        // The colour tags survive the metadata-free raw pipe.
        XCTAssertEqual(result.video.colorSpace, source.video.colorSpace ?? "bt470bg")
        XCTAssertEqual(result.video.colorRange, "tv")
    }

    func testTerminatingTheDecoderLeavesNoRunningProcess() throws {
        let tools = try TestSupport.requireTools()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 640, height: 480, durationSeconds: 10),
            in: directory
        )
        let source = try Probe(tools: tools).probe(url: fixture)
        let decode = DecodeProcess(ffmpeg: tools.ffmpeg, input: fixture, media: source)
        try decode.start()

        let identifier = decode.process.processIdentifier
        XCTAssertGreaterThan(identifier, 0)
        decode.terminate()
        _ = decode.process.waitUntilExit()
        XCTAssertFalse(decode.process.isRunning)
        // kill(pid, 0) succeeds only while a process with that id exists.
        XCTAssertEqual(kill(identifier, 0), -1)
    }

    func testEncodeFailureSurfacesFFmpegMessage() throws {
        let tools = try TestSupport.requireTools()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // An unwritable destination makes ffmpeg fail at open time.
        let output = URL(fileURLWithPath: "/upscale-not-writable/out.mkv")
        let process = FFmpegProcess(
            label: "ffmpeg (encode)",
            executable: tools.ffmpeg,
            arguments: [
                "-nostdin", "-v", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=25", "-t", "0.2",
                "-c:v", "hevc_videotoolbox", "-f", "matroska", output.path,
            ]
        )
        try process.start()

        XCTAssertThrowsError(try process.waitAndCheck()) { error in
            guard case let UpscaleError.processFailed(_, status, stderr) = error else {
                return XCTFail("expected processFailed, got \(error)")
            }
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(stderr.isEmpty, "the ffmpeg message should be captured")
        }
    }
}
