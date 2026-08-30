import XCTest
@testable import UpscaleCore

final class RationalTests: XCTestCase {
    func testParsesSlashForm() {
        XCTAssertEqual(Rational.parse("24000/1001"), Rational(24000, 1001))
    }

    func testParsesColonFormUsedByAspectRatios() {
        XCTAssertEqual(Rational.parse("16:9"), Rational(16, 9))
    }

    func testParsesBareInteger() {
        XCTAssertEqual(Rational.parse("25"), Rational(25, 1))
    }

    func testRejectsNonNumeric() {
        XCTAssertNil(Rational.parse("N/A"))
        XCTAssertNil(Rational.parse(""))
        XCTAssertNil(Rational.parse("   "))
    }

    func testFFmpegArgumentKeepsExactRatio() {
        XCTAssertEqual(Rational(24000, 1001).ffmpegArgument, "24000/1001")
        XCTAssertEqual(Rational(30000, 1001).doubleValue, 29.97, accuracy: 0.001)
    }

    func testReducedDividesByGCD() {
        XCTAssertEqual(Rational(1920, 1080).reduced, Rational(16, 9))
        XCTAssertEqual(Rational(0, 1).reduced, Rational(0, 1))
    }
}

final class PixelFormatBitDepthTests: XCTestCase {
    func testEightBitFormats() {
        for format in ["yuv420p", "yuv422p", "yuv444p", "nv12", "bgra", "rgb24"] {
            XCTAssertEqual(bitDepth(forPixelFormat: format), 8, format)
        }
    }

    func testHighBitDepthFormats() {
        XCTAssertEqual(bitDepth(forPixelFormat: "yuv420p10le"), 10)
        XCTAssertEqual(bitDepth(forPixelFormat: "yuv444p12be"), 12)
        XCTAssertEqual(bitDepth(forPixelFormat: "p010le"), 10)
        XCTAssertEqual(bitDepth(forPixelFormat: "gbrp16le"), 16)
    }
}
