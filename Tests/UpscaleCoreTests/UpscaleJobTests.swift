import Metal
import XCTest
@testable import UpscaleCore

/// WP4 acceptance: a real file goes in, an upscaled file with its other streams
/// intact comes out, and cancelling leaves nothing running.
final class UpscaleJobTests: XCTestCase {
    private func requireEnvironment() throws -> (FFmpegTools, MTLDevice) {
        let tools = try TestSupport.requireTools()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available.")
        }
        return (tools, device)
    }

    func testEndToEndUpscaleKeepsAudioSubtitlesAndDuration() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 320x240 keeps the test quick; the pipeline is size-independent.
        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 320, height: 240, durationSeconds: 1.0),
            in: directory
        )
        let output = directory.appendingPathComponent("upscaled.mkv")
        let job = UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(
                preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
                scale: 2,
                encoder: EncoderSettings(encoder: .hevc, quality: 60),
                output: output
            ),
            tools: tools,
            device: device
        )

        var phases: [UpscaleJobPhase] = []
        var lastProgress: UpscaleProgress?
        let source = try job.run { progress in
            if phases.last != progress.phase { phases.append(progress.phase) }
            lastProgress = progress
        }

        XCTAssertEqual(phases.first, .probing)
        XCTAssertTrue(phases.contains(.compilingShaders))
        XCTAssertEqual(phases.last, .finalizing)
        let progress = try XCTUnwrap(lastProgress)
        XCTAssertGreaterThan(progress.framesProcessed, 0)

        let result = try Probe(tools: tools).probe(url: output)
        XCTAssertEqual(result.video.width, source.video.width * 2)
        XCTAssertEqual(result.video.height, source.video.height * 2)
        XCTAssertEqual(result.video.codec, "hevc")
        XCTAssertEqual(result.video.realFrameRate, source.video.realFrameRate)
        XCTAssertEqual(result.audioStreams.count, 1)
        XCTAssertEqual(result.audioStreams[0].codec, "aac")
        XCTAssertEqual(result.subtitleStreams.count, 1)
        XCTAssertEqual(result.subtitleStreams[0].codec, "subrip")

        let sourceDuration = try XCTUnwrap(source.duration)
        let outputDuration = try XCTUnwrap(result.duration)
        let frameDuration = 1.0 / source.video.realFrameRate.doubleValue
        XCTAssertEqual(outputDuration, sourceDuration, accuracy: frameDuration * 1.5)

        // The output has to actually decode, not merely mux.
        let decoded = try ProcessRunner.run(
            executable: tools.ffmpeg,
            arguments: ["-nostdin", "-v", "error", "-i", output.path, "-f", "null", "-"]
        )
        XCTAssertEqual(decoded.terminationStatus, 0, decoded.standardError)
        XCTAssertTrue(decoded.standardError.isEmpty, decoded.standardError)
    }

    /// A skipped segment still produces frames: the output keeps its length, its
    /// chapters and its frame count, and only the shader chain is bypassed.
    func testSkippedSegmentIsPassedThrough() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var spec = TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 10.0)
        spec.chapters = [
            (title: "OP", start: 0, end: 3),
            (title: "Part A", start: 3, end: 7),
            (title: "ED", start: 7, end: 10),
        ]
        let fixture = try TestSupport.makeFixture(spec, in: directory)

        let media = try Probe(tools: tools).probe(url: fixture)
        XCTAssertEqual(media.chapters.count, 3)
        let skipRanges = ChapterSkipDetector.skippableRanges(in: media)
        XCTAssertEqual(skipRanges.map(\.label), ["OP", "ED"])

        let output = directory.appendingPathComponent("upscaled.mkv")
        let job = UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(
                preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
                scale: 2,
                skipRanges: skipRanges,
                output: output
            ),
            tools: tools,
            device: device
        )

        var lastProgress: UpscaleProgress?
        let source = try job.run { lastProgress = $0 }
        let progress = try XCTUnwrap(lastProgress)

        let sourceFrames = try frameCount(of: fixture, tools: tools)
        let outputFrames = try frameCount(of: output, tools: tools)
        XCTAssertEqual(outputFrames, sourceFrames)

        // Frames the plan marks inside the frames that actually exist: the last range
        // ends at the file's own end, where the source may be a frame short of the
        // nominal count.
        let plan = SkipPlan(ranges: skipRanges, frameRate: media.video.realFrameRate)
        let expected = (0..<sourceFrames).filter { plan.isSkipped(frame: $0) }.count
        XCTAssertEqual(progress.framesPassedThrough, expected)
        XCTAssertGreaterThan(expected, 0)
        XCTAssertLessThan(expected, sourceFrames)
        XCTAssertLessThanOrEqual(plan.skippedFrameCount - expected, 1)

        let result = try Probe(tools: tools).probe(url: output)
        XCTAssertEqual(result.video.width, source.video.width * 2)
        XCTAssertEqual(result.video.height, source.video.height * 2)
        XCTAssertEqual(result.chapters.count, 3)
        XCTAssertEqual(result.chapters.map(\.title), ["OP", "Part A", "ED"])

        let sourceDuration = try XCTUnwrap(source.duration)
        let outputDuration = try XCTUnwrap(result.duration)
        let frameDuration = 1.0 / source.video.realFrameRate.doubleValue
        XCTAssertEqual(outputDuration, sourceDuration, accuracy: frameDuration * 1.5)
    }

    /// Decoded frame count, which Matroska does not store in its header.
    private func frameCount(of url: URL, tools: FFmpegTools) throws -> Int {
        let result = try ProcessRunner.run(
            executable: tools.ffprobe,
            arguments: [
                "-v", "error", "-count_frames", "-select_streams", "v:0",
                "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", url.path,
            ]
        )
        let text = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(text) else {
            throw XCTSkip("ffprobe could not count frames: \(text) \(result.standardError)")
        }
        return count
    }

    /// Most modern anime encodes are 10-bit HEVC, and they now go through end to end
    /// and come back out 10-bit.
    func testTenBitInputIsAcceptedAndWrittenAsTenBit() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var spec = TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5)
        spec.pixelFormat = "yuv420p10le"
        spec.videoCodec = "libx265"
        spec.includeSubtitles = false
        spec.extraOutputArguments = ["-x265-params", "log-level=none"]
        let fixture = try TestSupport.makeFixture(spec, in: directory)

        let output = directory.appendingPathComponent("tenbit.mkv")
        let job = UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(
                scale: 2,
                encoder: EncoderSettings(encoder: .hevc, quality: 60, outputBitDepth: 10),
                output: output
            ),
            tools: tools,
            device: device
        )
        let source = try job.run()
        XCTAssertEqual(source.video.bitDepth, 10)

        let result = try Probe(tools: tools).probe(url: output)
        XCTAssertEqual(result.video.pixelFormat, "yuv420p10le")
        XCTAssertEqual(result.video.bitDepth, 10)
        XCTAssertEqual(result.video.width, source.video.width * 2)
        XCTAssertEqual(result.video.height, source.video.height * 2)

        let sourceDuration = try XCTUnwrap(source.duration)
        let outputDuration = try XCTUnwrap(result.duration)
        let frameDuration = 1.0 / source.video.realFrameRate.doubleValue
        XCTAssertEqual(outputDuration, sourceDuration, accuracy: frameDuration * 1.5)
    }

    /// A 10-bit source can still be written as 8-bit, and H.264 has no other option.
    func testTenBitSourceCanBeWrittenAsEightBit() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var spec = TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5)
        spec.pixelFormat = "yuv420p10le"
        spec.videoCodec = "libx265"
        spec.includeSubtitles = false
        spec.extraOutputArguments = ["-x265-params", "log-level=none"]
        let fixture = try TestSupport.makeFixture(spec, in: directory)

        let output = directory.appendingPathComponent("eightbit.mkv")
        let job = UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(
                scale: 2,
                encoder: EncoderSettings(encoder: .h264, quality: 60),
                output: output
            ),
            tools: tools,
            device: device
        )
        _ = try job.run()

        let result = try Probe(tools: tools).probe(url: output)
        XCTAssertEqual(result.video.bitDepth, 8)
        XCTAssertEqual(result.video.codec, "h264")
    }

    /// Asking H.264 for 10-bit has to fail before any file is opened, rather than
    /// silently writing 8-bit.
    func testTenBitOnH264IsRefusedBeforeAnythingIsWritten() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5),
            in: directory
        )
        let output = directory.appendingPathComponent("nope.mkv")
        let job = UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(
                scale: 2,
                encoder: EncoderSettings(encoder: .h264, quality: 60, outputBitDepth: 10),
                output: output
            ),
            tools: tools,
            device: device
        )

        XCTAssertThrowsError(try job.run()) { error in
            guard case let UpscaleError.unsupportedInput(reason) = error else {
                return XCTFail("expected unsupportedInput, got \(error)")
            }
            XCTAssertTrue(reason.contains("10-bit"), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancelMidJobLeavesNoOrphanFFmpegProcesses() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Long enough that the job is still running when cancel arrives.
        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 640, height: 480, durationSeconds: 20),
            in: directory
        )
        let output = directory.appendingPathComponent("cancelled.mkv")
        let job = UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(
                preset: try XCTUnwrap(Preset.preset(id: "mode-aa-hq")),
                scale: 2,
                output: output
            ),
            tools: tools,
            device: device
        )

        let started = expectation(description: "processing started")
        let finished = expectation(description: "run returned")
        var thrown: Error?
        var hasFulfilledStart = false

        DispatchQueue.global().async {
            do {
                try job.run { progress in
                    if progress.phase == .processing, progress.framesProcessed >= 2,
                       !hasFulfilledStart {
                        hasFulfilledStart = true
                        started.fulfill()
                    }
                }
            } catch {
                thrown = error
            }
            finished.fulfill()
        }

        wait(for: [started], timeout: 120)
        job.cancel()
        wait(for: [finished], timeout: 60)

        XCTAssertTrue(thrown is UpscaleCancelled, "expected UpscaleCancelled, got \(thrown as Any)")

        // Nothing may still be reading the fixture we are about to delete.
        let survivors = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", fixture.path]
        )
        XCTAssertEqual(
            survivors.terminationStatus, 1,
            "orphaned processes: \(survivors.standardOutput)"
        )
    }

    /// The writer runs on its own thread now, and most of its time is spent blocked in
    /// the pipe write. A cancel arriving then must still unblock it and tear both
    /// subprocesses down.
    func testCancelWhileTheWriterIsBlockedStillStops() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A cheap preset at 4x makes the encoder, not the GPU, the bottleneck, so the
        // consumer thread is almost certainly inside `write` when the cancel lands.
        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 640, height: 480, durationSeconds: 30),
            in: directory
        )
        let output = directory.appendingPathComponent("cancelled-writer.mkv")
        let job = UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(
                preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
                scale: 4,
                output: output
            ),
            tools: tools,
            device: device
        )

        let started = expectation(description: "processing started")
        let finished = expectation(description: "run returned")
        var thrown: Error?
        var hasFulfilledStart = false

        DispatchQueue.global().async {
            do {
                try job.run { progress in
                    if progress.phase == .processing, progress.framesProcessed >= 4,
                       !hasFulfilledStart {
                        hasFulfilledStart = true
                        started.fulfill()
                    }
                }
            } catch {
                thrown = error
            }
            finished.fulfill()
        }

        wait(for: [started], timeout: 120)
        job.cancel()
        wait(for: [finished], timeout: 60)

        XCTAssertTrue(thrown is UpscaleCancelled, "expected UpscaleCancelled, got \(thrown as Any)")
        let survivors = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", fixture.path]
        )
        XCTAssertEqual(
            survivors.terminationStatus, 1,
            "orphaned processes: \(survivors.standardOutput)"
        )
    }

    func testDefaultOutputURLSitsBesideTheInput() {
        let input = URL(fileURLWithPath: "/videos/Episode 01.mkv")
        let output = UpscaleJobSettings.defaultOutputURL(for: input, scale: 2)
        XCTAssertEqual(output.path, "/videos/Episode 01.2x.mkv")
    }
}
