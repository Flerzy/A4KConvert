import XCTest
@testable import UpscaleCore

final class SkipRangesTests: XCTestCase {
    func testOverlappingAndTouchingRangesMerge() {
        let ranges = SkipRanges.normalized(
            [
                SkipRange(start: 10, end: 20, label: "OP"),
                SkipRange(start: 15, end: 25),
                SkipRange(start: 25, end: 30),
                SkipRange(start: 40, end: 50, label: "ED"),
            ],
            duration: nil
        )
        XCTAssertEqual(ranges.map(\.start), [10, 40])
        XCTAssertEqual(ranges.map(\.end), [30, 50])
        XCTAssertEqual(ranges.first?.label, "OP")
    }

    func testInvertedAndEmptyRangesAreDropped() {
        let ranges = SkipRanges.normalized(
            [
                SkipRange(start: 20, end: 10),
                SkipRange(start: 5, end: 5),
                SkipRange(start: 1, end: 2),
            ],
            duration: nil
        )
        XCTAssertEqual(ranges, [SkipRange(start: 1, end: 2)])
    }

    func testRangesAreClampedToTheDuration() {
        let ranges = SkipRanges.normalized(
            [
                SkipRange(start: -5, end: 4),
                SkipRange(start: 8, end: 100),
                SkipRange(start: 30, end: 40),
            ],
            duration: 10
        )
        XCTAssertEqual(ranges, [SkipRange(start: 0, end: 4), SkipRange(start: 8, end: 10)])
    }

    func testUnsortedInputComesBackSorted() {
        let ranges = SkipRanges.normalized(
            [SkipRange(start: 60, end: 70), SkipRange(start: 0, end: 10)],
            duration: nil
        )
        XCTAssertEqual(ranges.map(\.start), [0, 60])
    }

    func testTotalDurationSumsTheRanges() {
        XCTAssertEqual(
            SkipRanges.totalDuration([SkipRange(start: 0, end: 90), SkipRange(start: 100, end: 130)]),
            120
        )
    }

    // MARK: - Kept ranges

    func testKeptRangesAreTheComplement() {
        XCTAssertEqual(
            SkipRanges.kept(from: [SkipRange(start: 90, end: 1440)], duration: 1440),
            [SkipRange(start: 0, end: 90)]
        )
        XCTAssertEqual(
            SkipRanges.kept(from: [SkipRange(start: 0, end: 90)], duration: 1440),
            [SkipRange(start: 90, end: 1440)]
        )
        XCTAssertEqual(
            SkipRanges.kept(
                from: [SkipRange(start: 0, end: 90), SkipRange(start: 1350, end: 1440)],
                duration: 1440
            ),
            [SkipRange(start: 90, end: 1350)]
        )
        XCTAssertEqual(
            SkipRanges.kept(from: [SkipRange(start: 60, end: 120)], duration: 300),
            [SkipRange(start: 0, end: 60), SkipRange(start: 120, end: 300)]
        )
    }

    func testKeptRangesWithNothingSkippedAreTheWholeFile() {
        XCTAssertEqual(
            SkipRanges.kept(from: [], duration: 600), [SkipRange(start: 0, end: 600)]
        )
    }

    func testSkippingEverythingKeepsNothing() {
        XCTAssertEqual(SkipRanges.kept(from: [SkipRange(start: 0, end: 600)], duration: 600), [])
    }

    /// Without a duration the tail is open-ended rather than dropped.
    func testKeptRangesWithoutADurationRunToTheEnd() {
        let kept = SkipRanges.kept(from: [SkipRange(start: 0, end: 90)], duration: nil)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].start, 90)
        XCTAssertEqual(kept[0].end, .infinity)
    }

    // MARK: - Frame mapping

    private let ntsc = Rational(24000, 1001)

    /// 24000/1001 is the rate that makes naive rounding drift, so the boundaries are
    /// checked frame by frame.
    func testFrameMappingAtTwentyThreeNineSevenSix() {
        let plan = SkipPlan(ranges: [SkipRange(start: 3, end: 7)], frameRate: ntsc)
        // 3 s x 23.976 = 71.928 → first skipped frame is 72; 7 s → 167.83 → 168.
        XCTAssertEqual(plan.frameRanges, [72..<168])
        XCTAssertFalse(plan.isSkipped(frame: 71))
        XCTAssertTrue(plan.isSkipped(frame: 72))
        XCTAssertTrue(plan.isSkipped(frame: 167))
        XCTAssertFalse(plan.isSkipped(frame: 168))
        XCTAssertEqual(plan.skippedFrameCount, 96)
    }

    /// At a whole-number rate the range ends exactly on a frame, and that frame belongs
    /// to the next segment because the interval is half-open.
    func testWholeNumberRateKeepsTheEndFrameOutside() {
        let plan = SkipPlan(ranges: [SkipRange(start: 1, end: 3)], frameRate: Rational(25, 1))
        XCTAssertEqual(plan.frameRanges, [25..<75])
        XCTAssertTrue(plan.isSkipped(frame: 25))
        XCTAssertTrue(plan.isSkipped(frame: 74))
        XCTAssertFalse(plan.isSkipped(frame: 75))
    }

    func testFrameZeroIsSkippedWhenARangeStartsAtZero() {
        let plan = SkipPlan(ranges: [SkipRange(start: 0, end: 1)], frameRate: Rational(25, 1))
        XCTAssertTrue(plan.isSkipped(frame: 0))
        XCTAssertEqual(plan.skippedFrameCount, 25)
    }

    func testSeveralRangesAreSearchedIndependently() {
        let plan = SkipPlan(
            ranges: [SkipRange(start: 0, end: 2), SkipRange(start: 10, end: 12)],
            frameRate: Rational(25, 1)
        )
        XCTAssertEqual(plan.frameRanges, [0..<50, 250..<300])
        XCTAssertFalse(plan.isSkipped(frame: 50))
        XCTAssertFalse(plan.isSkipped(frame: 249))
        XCTAssertTrue(plan.isSkipped(frame: 299))
        XCTAssertFalse(plan.isSkipped(frame: 300))
        XCTAssertEqual(plan.skippedFrameCount, 100)
    }

    func testNoRangesSkipsNothing() {
        let plan = SkipPlan(ranges: [], frameRate: ntsc)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.isSkipped(frame: 0))
        XCTAssertEqual(plan.skippedFrameCount, 0)
    }
}

final class TimecodeTests: XCTestCase {
    func testParsesEveryAcceptedShape() {
        XCTAssertEqual(Timecode.parse("12"), 12)
        XCTAssertEqual(Timecode.parse("1:30"), 90)
        XCTAssertEqual(Timecode.parse("1:00:00"), 3600)
        XCTAssertEqual(Timecode.parse("0:01:30.5"), 90.5)
        XCTAssertEqual(try XCTUnwrap(Timecode.parse("90.25")), 90.25, accuracy: 1e-9)
        XCTAssertEqual(Timecode.parse("  2:03  "), 123)
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(Timecode.parse(""))
        XCTAssertNil(Timecode.parse("abc"))
        XCTAssertNil(Timecode.parse("1:2:3:4"))
        XCTAssertNil(Timecode.parse("-5"))
        XCTAssertNil(Timecode.parse("1:90"))
        XCTAssertNil(Timecode.parse("1:"))
        XCTAssertNil(Timecode.parse("1.5:30"))
    }

    func testFormatsAndRoundTrips() throws {
        XCTAssertEqual(Timecode.format(0), "0:00.0")
        XCTAssertEqual(Timecode.format(90.5), "1:30.5")
        XCTAssertEqual(Timecode.format(3661.2), "1:01:01.2")
        for seconds in [0.0, 9.9, 90.5, 3661.2] {
            let parsed = try XCTUnwrap(Timecode.parse(Timecode.format(seconds)))
            XCTAssertEqual(parsed, seconds, accuracy: 0.05)
        }
    }
}

final class ChapterSkipDetectorTests: XCTestCase {
    func testTitleTable() {
        let skippable = [
            "OP", "op", "ED2", "op 1", "Opening", "Ending Theme", "opening credits",
            "Intro", "Outro", "Preview", "Next Episode", "next time preview",
            " ED ",
        ]
        for title in skippable {
            XCTAssertTrue(ChapterSkipDetector.isSkippableTitle(title), title)
        }

        let kept = [
            "Part A", "Part B", "Avant", "Episode 3", "1", "Chapter 2", "Pretending",
            "Operation", "Edge of Tomorrow", "opera", "", "   ",
        ]
        for title in kept {
            XCTAssertFalse(ChapterSkipDetector.isSkippableTitle(title), title)
        }
    }

    func testDetectorTurnsChaptersIntoNormalizedRanges() {
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
            attachmentStreams: [],
            chapters: [
                Chapter(start: 0, end: 90, title: "OP"),
                Chapter(start: 90, end: 95, title: "Part A"),
                Chapter(start: 95, end: 120, title: "ED"),
            ]
        )
        XCTAssertEqual(
            ChapterSkipDetector.skippableRanges(in: media),
            [
                SkipRange(start: 0, end: 90, label: "OP"),
                SkipRange(start: 95, end: 100, label: "ED"),
            ]
        )
    }
}
