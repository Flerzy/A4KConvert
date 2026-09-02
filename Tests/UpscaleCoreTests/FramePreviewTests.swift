import CoreGraphics
import Metal
import XCTest
@testable import UpscaleCore

final class FramePreviewTests: XCTestCase {
    private func requireEnvironment() throws -> (FFmpegTools, MTLDevice) {
        let tools = try TestSupport.requireTools()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available.")
        }
        return (tools, device)
    }

    func testRendersBothSidesAtTheTargetSize() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Real line art rather than testsrc2: the whole point of the preview is the
        // difference the chain makes, and on synthetic patterns there is barely one.
        let fixture = try makeAnimeClip(in: directory, tools: tools)
        let settings = UpscaleJobSettings(
            preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
            scale: 2,
            output: directory.appendingPathComponent("unused.mkv")
        )

        let preview = try FramePreview.render(
            input: fixture, at: 1.0, settings: settings, tools: tools, device: device
        )

        XCTAssertEqual(preview.original.width, 1280)
        XCTAssertEqual(preview.original.height, 960)
        XCTAssertEqual(preview.upscaled.width, 1280)
        XCTAssertEqual(preview.upscaled.height, 960)
        XCTAssertEqual(preview.seconds, 1.0, accuracy: 0.001)

        // The two sides have to be visibly different, or the preview tells the user
        // nothing about the preset. The mean stays low — the chain changes edges, and
        // most of an anime frame is flat colour — so the edges are what is measured:
        // measured at 0.80/255 mean with 3.2% of samples 8 levels apart or more.
        let (mean, changedFraction) = try compare(preview.original, preview.upscaled)
        print("preview original vs upscaled: \(mean)/255 mean, \(changedFraction) changed")
        XCTAssertGreaterThan(mean, 0.3)
        XCTAssertGreaterThan(changedFraction, 0.01)
    }

    /// A request past the end still returns the last frame rather than failing.
    func testSeekIsClampedToTheFile() throws {
        let (tools, device) = try requireEnvironment()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 1.0),
            in: directory
        )
        let settings = UpscaleJobSettings(
            scale: 2, output: directory.appendingPathComponent("unused.mkv")
        )
        let preview = try FramePreview.render(
            input: fixture, at: 99, settings: settings, tools: tools, device: device
        )
        XCTAssertLessThan(preview.seconds, 1.0)
        XCTAssertEqual(preview.upscaled.width, 320)
    }

    func testSeekArgumentsPutTheSeekBeforeTheInput() throws {
        let media = MediaInfo(
            path: "in.mkv",
            formatName: "matroska,webm",
            duration: 100,
            video: VideoStream(
                index: 0, codec: "h264", width: 640, height: 480, pixelFormat: "yuv420p",
                bitDepth: 8, realFrameRate: Rational(25, 1), averageFrameRate: Rational(25, 1),
                sampleAspectRatio: .one, nominalFrameCount: 2500, duration: 100,
                colorRange: nil, colorSpace: nil, colorPrimaries: nil, colorTransfer: nil
            ),
            audioStreams: [],
            subtitleStreams: [],
            attachmentStreams: []
        )
        let arguments = FramePreview.arguments(
            input: URL(fileURLWithPath: "/v/in.mkv"), at: 12.5, media: media
        )
        let seek = try XCTUnwrap(arguments.firstIndex(of: "-ss"))
        let input = try XCTUnwrap(arguments.firstIndex(of: "-i"))
        XCTAssertLessThan(seek, input, "a seek after -i decodes from the start")
        XCTAssertEqual(arguments[seek + 1], "12.500")
        XCTAssertTrue(arguments.contains("-frames:v"))
    }

    /// A three-second clip of the 640x480 anime golden source.
    private func makeAnimeClip(in directory: URL, tools: FFmpegTools) throws -> URL {
        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: "anime4k_source_640x480", withExtension: "png",
                subdirectory: "Fixtures"
            )
        )
        let output = directory.appendingPathComponent("anime.mkv")
        let result = try ProcessRunner.run(
            executable: tools.ffmpeg,
            arguments: [
                "-nostdin", "-v", "error", "-y",
                "-loop", "1", "-framerate", "24", "-i", source.path,
                "-t", "3", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "12",
                "-pix_fmt", "yuv420p", output.path,
            ]
        )
        guard result.terminationStatus == 0 else {
            throw UpscaleError.processFailed(
                tool: "ffmpeg (fixture)", status: result.terminationStatus,
                stderr: result.standardError
            )
        }
        return output
    }

    /// Mean absolute difference, plus the fraction of samples at least 8 levels apart.
    private func compare(
        _ lhs: CGImage, _ rhs: CGImage
    ) throws -> (mean: Double, changedFraction: Double) {
        let left = try bytes(of: lhs)
        let right = try bytes(of: rhs)
        XCTAssertEqual(left.count, right.count)
        var total = 0
        var changed = 0
        for index in left.indices {
            let difference = abs(Int(left[index]) - Int(right[index]))
            total += difference
            if difference >= 8 { changed += 1 }
        }
        return (
            Double(total) / Double(left.count),
            Double(changed) / Double(left.count)
        )
    }

    private func bytes(of image: CGImage) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return [UInt8](data)
    }
}
