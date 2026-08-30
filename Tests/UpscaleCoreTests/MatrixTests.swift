import Metal
import XCTest
@testable import UpscaleCore

/// WP6 verification matrix: containers, source codecs, frame rates, aspect ratios and
/// stream layouts, each checked end to end for duration, geometry and stream survival.
///
/// Opt-in because it encodes and decodes a lot of video:
/// `UPSCALE_MATRIX=1 swift test --filter MatrixTests`.
final class MatrixTests: XCTestCase {
    private struct Case {
        let name: String
        var spec: TestSupport.FixtureSpec
        var outputExtension: String?
        var scale = 2
    }

    private func requireMatrix() throws -> (FFmpegTools, MTLDevice) {
        guard ProcessInfo.processInfo.environment["UPSCALE_MATRIX"] == "1" else {
            throw XCTSkip("Set UPSCALE_MATRIX=1 to run the verification matrix.")
        }
        let tools = try TestSupport.requireTools()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available.")
        }
        return (tools, device)
    }

    private static var baseSpec: TestSupport.FixtureSpec {
        var spec = TestSupport.FixtureSpec()
        spec.width = 320
        spec.height = 240
        spec.durationSeconds = 1.0
        return spec
    }

    private static var cases: [Case] {
        var cases: [Case] = []

        func add(_ name: String, _ configure: (inout TestSupport.FixtureSpec) -> Void,
                 outputExtension: String? = nil, scale: Int = 2) {
            var spec = baseSpec
            configure(&spec)
            cases.append(Case(name: name, spec: spec, outputExtension: outputExtension, scale: scale))
        }

        // Containers.
        add("mkv/h264") { _ in }
        add("mp4/h264") { spec in
            spec.container = "mp4"
            // SRT cannot be stream-copied into MP4; the encoder converts it to mov_text.
        }
        add("mkv->mp4") { _ in }
        add("mp4->mkv", { spec in spec.container = "mp4" }, outputExtension: "mkv")

        // Source codecs. AV1 decodes on the CPU through dav1d, which is fine here.
        add("hevc source") { spec in
            spec.videoCodec = "libx265"
            spec.extraOutputArguments = ["-x265-params", "log-level=none"]
        }
        add("av1 source") { spec in
            spec.videoCodec = "libsvtav1"
            spec.includeSubtitles = false
        }

        // Frame rates, including the two that are not integers.
        add("23.976 fps") { spec in spec.frameRate = Rational(24000, 1001) }
        add("25 fps") { spec in spec.frameRate = Rational(25, 1) }
        add("60 fps") { spec in spec.frameRate = Rational(60, 1) }
        add("29.97 fps") { spec in spec.frameRate = Rational(30000, 1001) }

        // Stream layouts.
        add("no audio") { spec in
            spec.includeAudio = false
            spec.includeSubtitles = false
        }
        add("multi audio") { spec in spec.audioTrackCount = 3 }

        // Anamorphic: 4:3 PAL pixels, which uniform scaling must not silently square up.
        add("anamorphic sar 64:45") { spec in
            spec.width = 352
            spec.height = 288
            spec.sampleAspectRatio = Rational(64, 45)
        }

        // Colour: a BT.601-flagged source has to come out still flagged BT.601, since
        // the raw pipe between the two ffmpeg processes carries no metadata.
        add("bt601 tagged") { spec in
            spec.colorspace = "bt470bg"
            spec.colorPrimaries = "bt470bg"
            spec.colorTransfer = "smpte170m"
            spec.colorRange = "tv"
        }
        add("bt709 tagged") { spec in
            spec.colorspace = "bt709"
            spec.colorPrimaries = "bt709"
            spec.colorTransfer = "bt709"
            spec.colorRange = "tv"
        }

        // Matroska carries font attachments for styled subtitles; they must survive.
        add("mkv attachments") { spec in
            spec.attachments = ["/System/Library/Fonts/Monaco.ttf"]
        }

        // Scale factors.
        add("4x", { _ in }, scale: 4)
        // Odd dimensions: 2x of an odd size is even, so this must simply work. 4:2:0
        // cannot represent odd sizes at all, so the source has to be 4:4:4.
        add("odd dimensions") { spec in
            spec.width = 321
            spec.height = 241
            spec.pixelFormat = "yuv444p"
        }

        return cases
    }

    func testMatrix() throws {
        let (tools, device) = try requireMatrix()
        let probe = Probe(tools: tools)
        var report: [String] = []

        for testCase in MatrixTests.cases {
            let directory = try TestSupport.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let fixture = try TestSupport.makeFixture(testCase.spec, in: directory)
            let source = try probe.probe(url: fixture)
            let outputExtension = testCase.outputExtension ?? testCase.spec.container
            let output = directory.appendingPathComponent("out.\(outputExtension)")

            let job = UpscaleJob(
                input: fixture,
                settings: UpscaleJobSettings(
                    preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
                    scale: testCase.scale,
                    encoder: EncoderSettings(encoder: .hevc, quality: 55),
                    output: output
                ),
                tools: tools,
                device: device
            )

            do {
                try job.run()
            } catch {
                let detail = JobQueue.describe(error).detail.map { "\n\($0)" } ?? ""
                XCTFail("\(testCase.name): \(error)\(detail)")
                continue
            }

            let result = try probe.probe(url: output)

            // Geometry.
            XCTAssertEqual(
                result.video.width, source.video.width * testCase.scale, "\(testCase.name) width"
            )
            XCTAssertEqual(
                result.video.height, source.video.height * testCase.scale, "\(testCase.name) height"
            )

            // Frame rate stays exactly rational.
            XCTAssertEqual(
                result.video.realFrameRate.reduced,
                source.video.realFrameRate.reduced,
                "\(testCase.name) frame rate"
            )

            // Pixel aspect ratio survives, so an anamorphic source still displays right.
            XCTAssertEqual(
                result.video.sampleAspectRatio.reduced,
                source.video.sampleAspectRatio.reduced,
                "\(testCase.name) sample aspect ratio"
            )

            // Streams.
            XCTAssertEqual(
                result.audioStreams.count, source.audioStreams.count, "\(testCase.name) audio count"
            )
            let container0 = OutputContainer.forExtension(outputExtension)
            XCTAssertEqual(
                result.attachmentStreams.count,
                container0.supportsAttachments ? source.attachmentStreams.count : 0,
                "\(testCase.name) attachment count"
            )
            let container = OutputContainer.forExtension(outputExtension)
            if !source.subtitleStreams.isEmpty {
                XCTAssertEqual(
                    result.subtitleStreams.count,
                    source.subtitleStreams.count,
                    "\(testCase.name) subtitle count"
                )
                let expectedCodec = container == .matroska ? "subrip" : "mov_text"
                XCTAssertEqual(
                    result.subtitleStreams.first?.codec, expectedCodec,
                    "\(testCase.name) subtitle codec"
                )
            }

            // Colour tags survive the metadata-free raw pipe.
            let expected = ColorProperties.from(source.video)
            XCTAssertEqual(result.video.colorSpace, expected.matrix, "\(testCase.name) matrix")
            XCTAssertEqual(result.video.colorRange, expected.range, "\(testCase.name) range")
            XCTAssertEqual(
                result.video.colorPrimaries, expected.primaries, "\(testCase.name) primaries"
            )
            XCTAssertEqual(
                result.video.colorTransfer, expected.transfer, "\(testCase.name) transfer"
            )

            // Duration, within one frame.
            let frameDuration = 1.0 / source.video.realFrameRate.doubleValue
            let sourceDuration = try XCTUnwrap(source.duration, "\(testCase.name) source duration")
            let outputDuration = try XCTUnwrap(result.duration, "\(testCase.name) output duration")
            XCTAssertEqual(
                outputDuration, sourceDuration,
                accuracy: frameDuration * 1.5,
                "\(testCase.name) duration"
            )

            // A/V sync: the audio must not have drifted against the video.
            if !source.audioStreams.isEmpty {
                let drift = try MatrixTests.audioVideoDrift(tools: tools, url: output)
                XCTAssertLessThan(
                    abs(drift), frameDuration * 2, "\(testCase.name) a/v drift \(drift)s"
                )
            }

            // The whole file has to decode without a single error.
            let decoded = try ProcessRunner.run(
                executable: tools.ffmpeg,
                arguments: ["-nostdin", "-v", "error", "-i", output.path, "-f", "null", "-"]
            )
            XCTAssertEqual(
                decoded.terminationStatus, 0, "\(testCase.name) decode: \(decoded.standardError)"
            )
            XCTAssertTrue(
                decoded.standardError.isEmpty, "\(testCase.name) decode: \(decoded.standardError)"
            )

            report.append(String(
                format: "%-22@ %4dx%-4d -> %4dx%-4d  %@ fps  sar %@  %d audio  ok",
                testCase.name as NSString,
                source.video.width, source.video.height,
                result.video.width, result.video.height,
                result.video.realFrameRate.ffmpegArgument as NSString,
                result.video.sampleAspectRatio.reduced.ffmpegArgument as NSString,
                result.audioStreams.count
            ))
        }

        print(report.joined(separator: "\n"))
    }

    /// Difference between the video and audio stream end times, from ffprobe packet data.
    ///
    /// A frame-rate or timebase mistake shows up here as a growing gap between the two.
    private static func audioVideoDrift(tools: FFmpegTools, url: URL) throws -> Double {
        func endTime(of specifier: String) throws -> Double {
            let result = try ProcessRunner.run(
                executable: tools.ffprobe,
                arguments: [
                    "-v", "error",
                    "-select_streams", specifier,
                    "-show_entries", "packet=pts_time,duration_time",
                    "-of", "csv=p=0",
                    url.path,
                ]
            )
            var latest = 0.0
            for line in result.standardOutput.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard let start = Double(fields.first ?? "") else { continue }
                let duration = fields.count > 1 ? (Double(fields[1]) ?? 0) : 0
                latest = max(latest, start + duration)
            }
            return latest
        }
        return try endTime(of: "v:0") - endTime(of: "a:0")
    }

    /// 10-bit input is refused rather than silently converted, in every container.
    func testTenBitIsRefusedAcrossContainers() throws {
        let (tools, device) = try requireMatrix()
        for container in ["mkv", "mp4"] {
            let directory = try TestSupport.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            var spec = MatrixTests.baseSpec
            spec.container = container
            spec.pixelFormat = "yuv420p10le"
            spec.videoCodec = "libx265"
            spec.includeSubtitles = false
            spec.extraOutputArguments = ["-x265-params", "log-level=none"]
            let fixture = try TestSupport.makeFixture(spec, in: directory)

            let output = directory.appendingPathComponent("out.\(container)")
            let job = UpscaleJob(
                input: fixture,
                settings: UpscaleJobSettings(scale: 2, output: output),
                tools: tools,
                device: device
            )
            XCTAssertThrowsError(try job.run(), container) { error in
                guard case let UpscaleError.unsupportedInput(reason) = error else {
                    return XCTFail("\(container): expected unsupportedInput, got \(error)")
                }
                XCTAssertTrue(reason.contains("10-bit"), reason)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), container)
        }
    }
}
