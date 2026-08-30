import Foundation
import XCTest
@testable import UpscaleCore

/// Shared helpers for tests that need real ffmpeg and a real media file.
enum TestSupport {
    /// Resolved once: every test that shells out uses the same binaries.
    static let tools: FFmpegTools? = try? FFmpegLocator.locate()

    /// Skips the calling test when ffmpeg is not installed, rather than failing it.
    static func requireTools(file: StaticString = #filePath, line: UInt = #line) throws -> FFmpegTools {
        guard let tools else {
            throw XCTSkip("ffmpeg/ffprobe not installed; skipping integration test.")
        }
        return tools
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upscale-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Describes a fixture to synthesise, so tests do not carry binary media in the repo.
    struct FixtureSpec {
        var width = 320
        var height = 240
        var frameRate = Rational(24000, 1001)
        var durationSeconds = 2.0
        var videoCodec = "libx264"
        var pixelFormat = "yuv420p"
        var includeAudio = true
        /// How many audio streams to mux in, when `includeAudio` is true.
        var audioTrackCount = 1
        var includeSubtitles = true
        var container = "mkv"
        /// Font files to attach, exercising Matroska attachment passthrough.
        var attachments: [String] = []
        /// When set, the subtitle track carries two events this many seconds apart,
        /// reproducing the long dialogue-free stretches real subtitles have.
        var subtitleGapSeconds: Double?
        /// Non-square pixels, e.g. `Rational(64, 45)` for 4:3 anamorphic PAL.
        var sampleAspectRatio: Rational?
        /// Colour tags to stamp on the source, for the colour round-trip checks.
        var colorspace: String?
        var colorPrimaries: String?
        var colorTransfer: String?
        var colorRange: String?
        var extraOutputArguments: [String] = []
    }

    /// Builds a test file with ffmpeg's synthetic sources.
    @discardableResult
    static func makeFixture(
        _ spec: FixtureSpec = FixtureSpec(),
        in directory: URL,
        name: String = "fixture"
    ) throws -> URL {
        let tools = try requireTools()
        let output = directory.appendingPathComponent("\(name).\(spec.container)")

        // testsrc2 only generates even sizes, so an odd-dimension fixture is cropped
        // out of the next even one.
        let generatedWidth = spec.width + (spec.width % 2)
        let generatedHeight = spec.height + (spec.height % 2)
        var arguments = [
            "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "testsrc2=size=\(generatedWidth)x\(generatedHeight)"
                + ":rate=\(spec.frameRate.ffmpegArgument)",
        ]
        var mapArguments = ["-map", "0:v"]
        var codecArguments = [
            "-c:v", spec.videoCodec,
            "-preset", "ultrafast",
            "-pix_fmt", spec.pixelFormat,
        ]
        if spec.videoCodec != "libx264" {
            codecArguments.removeAll { $0 == "-preset" || $0 == "ultrafast" }
        }
        var nextInput = 1

        if spec.includeAudio {
            let languages = ["jpn", "eng", "ger"]
            for track in 0..<spec.audioTrackCount {
                let frequency = 440 + track * 110
                arguments += [
                    "-f", "lavfi",
                    "-i", "sine=frequency=\(frequency):sample_rate=48000",
                ]
                mapArguments += ["-map", "\(nextInput):a"]
                codecArguments += [
                    "-metadata:s:a:\(track)", "language=\(languages[track % languages.count])",
                ]
                nextInput += 1
            }
            codecArguments += ["-c:a", "aac"]
        }

        if spec.includeSubtitles {
            let subtitles = directory.appendingPathComponent("\(name).srt")
            try subtitleText(duration: spec.durationSeconds, gap: spec.subtitleGapSeconds).write(
                to: subtitles, atomically: true, encoding: .utf8
            )
            arguments += ["-i", subtitles.path]
            mapArguments += ["-map", "\(nextInput):s"]
            // MP4/MOV have no SRT track type; text subtitles have to be mov_text there.
            let subtitleCodec = spec.container == "mkv" ? "srt" : "mov_text"
            codecArguments += ["-c:s", subtitleCodec, "-metadata:s:s:0", "language=eng"]
            nextInput += 1
        }

        arguments += mapArguments
        arguments += ["-t", String(spec.durationSeconds)]
        arguments += codecArguments

        var filters: [String] = []
        if generatedWidth != spec.width || generatedHeight != spec.height {
            // `crop` aligns to the chroma grid, so 4:2:0 frames silently round back to
            // even. Convert first, then crop.
            filters.append("format=\(spec.pixelFormat)")
            filters.append("crop=\(spec.width):\(spec.height)")
        }
        if let sar = spec.sampleAspectRatio {
            filters.append("setsar=\(sar.numerator)/\(sar.denominator)")
        }
        if !filters.isEmpty {
            arguments += ["-vf", filters.joined(separator: ",")]
        }
        if let colorspace = spec.colorspace { arguments += ["-colorspace", colorspace] }
        if let primaries = spec.colorPrimaries { arguments += ["-color_primaries", primaries] }
        if let transfer = spec.colorTransfer { arguments += ["-color_trc", transfer] }
        if let range = spec.colorRange { arguments += ["-color_range", range] }
        for attachment in spec.attachments {
            arguments += ["-attach", attachment]
        }
        for index in spec.attachments.indices {
            arguments += ["-metadata:s:t:\(index)", "mimetype=application/x-truetype-font"]
        }
        arguments += spec.extraOutputArguments
        arguments.append(output.path)

        let result = try ProcessRunner.run(executable: tools.ffmpeg, arguments: arguments)
        guard result.terminationStatus == 0 else {
            throw UpscaleError.processFailed(
                tool: "ffmpeg (fixture)",
                status: result.terminationStatus,
                stderr: result.standardError
            )
        }
        return output
    }

    private static func subtitleText(duration: Double, gap: Double?) -> String {
        guard let gap else {
            let end = max(1.0, duration - 0.2)
            return """
            1
            00:00:00,100 --> \(timecode(end))
            Upscale fixture subtitle

            """
        }
        // Two events separated by a silent stretch, which is what pushes ffmpeg's
        // interleaver past max_interleave_delta.
        let secondStart = min(gap, max(0.5, duration - 1))
        return """
        1
        00:00:00,100 --> \(timecode(0.6))
        first line

        2
        \(timecode(secondStart)) --> \(timecode(min(duration - 0.1, secondStart + 0.5)))
        line after a long silence

        """
    }

    private static func timecode(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        let (whole, remainder) = milliseconds.quotientAndRemainder(dividingBy: 1000)
        let (minutes, secs) = whole.quotientAndRemainder(dividingBy: 60)
        let (hours, mins) = minutes.quotientAndRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%02d,%03d", hours, mins, secs, remainder)
    }
}
