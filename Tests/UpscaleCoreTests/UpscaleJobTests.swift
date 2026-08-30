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

    func testTenBitInputIsRefusedBeforeAnythingIsWritten() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(
                width: 160, height: 120, durationSeconds: 0.5,
                pixelFormat: "yuv420p10le", includeSubtitles: false
            ),
            in: directory
        )
        let output = directory.appendingPathComponent("nope.mkv")
        let job = UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(scale: 2, output: output),
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

    func testDefaultOutputURLSitsBesideTheInput() {
        let input = URL(fileURLWithPath: "/videos/Episode 01.mkv")
        let output = UpscaleJobSettings.defaultOutputURL(for: input, scale: 2)
        XCTAssertEqual(output.path, "/videos/Episode 01.2x.mkv")
    }
}
