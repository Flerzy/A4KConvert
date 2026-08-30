import XCTest
@testable import UpscaleCore

final class FFmpegStderrParserTests: XCTestCase {
    func testSeparatesProgressRecordsFromLogLines() {
        var parser = FFmpegStderrParser()
        let chunk = """
        [libx264 @ 0x14f008200] using cpu capabilities: NEON
        frame=42
        fps=23.5
        out_time_us=1750000
        speed=1.02x
        progress=continue
        Error while decoding stream #0:0: Invalid data found
        """
        let logLines = parser.consume(Data(chunk.utf8)) + parser.finish()

        XCTAssertEqual(logLines, [
            "[libx264 @ 0x14f008200] using cpu capabilities: NEON",
            "Error while decoding stream #0:0: Invalid data found",
        ])
        XCTAssertEqual(parser.progress.frame, 42)
        XCTAssertEqual(parser.progress.fps, 23.5)
        XCTAssertEqual(parser.progress.outTimeMicroseconds, 1_750_000)
        XCTAssertEqual(parser.progress.speed, 1.02)
        XCTAssertEqual(parser.progress.outTimeSeconds, 1.75)
        XCTAssertFalse(parser.progress.isFinished)
    }

    func testRecordsSplitAcrossChunks() {
        var parser = FFmpegStderrParser()
        XCTAssertTrue(parser.consume(Data("fra".utf8)).isEmpty)
        XCTAssertTrue(parser.consume(Data("me=7\npro".utf8)).isEmpty)
        XCTAssertEqual(parser.progress.frame, 7)
        _ = parser.consume(Data("gress=end\n".utf8))
        XCTAssertTrue(parser.progress.isFinished)
    }

    func testLogLinesContainingEqualsAreNotProgress() {
        var parser = FFmpegStderrParser()
        let lines = parser.consume(Data("Stream #0:0 -> #0:0 (rawvideo (native) -> hevc)\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertNil(parser.progress.frame)
    }

    func testOutTimeMillisecondsFieldIsActuallyMicroseconds() {
        var parser = FFmpegStderrParser()
        _ = parser.consume(Data("out_time_ms=2000000\n".utf8))
        XCTAssertEqual(parser.progress.outTimeSeconds, 2.0)
    }
}

final class UpscaleErrorTests: XCTestCase {
    func testDecisiveLineSkipsFFmpegBanner() {
        let stderr = """
        ffmpeg version 9.0.1 Copyright (c) 2000-2026 the FFmpeg developers
          built with Apple clang version 21.0.0
          configuration: --prefix=/opt/homebrew
          libavutil      60.  8.100 / 60.  8.100
        pipe:0: Invalid data found when processing input
        """
        XCTAssertEqual(
            UpscaleError.decisiveLine(in: stderr),
            "pipe:0: Invalid data found when processing input"
        )
    }

    func testDecisiveLineOfEmptyStderr() {
        XCTAssertEqual(UpscaleError.decisiveLine(in: "   \n\n"), "")
    }
}
