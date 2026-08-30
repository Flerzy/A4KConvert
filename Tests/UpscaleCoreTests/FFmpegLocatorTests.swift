import XCTest
@testable import UpscaleCore

final class FFmpegLocatorTests: XCTestCase {
    func testFindsInstalledTools() throws {
        let tools = try TestSupport.requireTools()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tools.ffmpeg.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tools.ffprobe.path))
    }

    func testSearchOrderPutsBundleBeforeHomebrewBeforePath() {
        let directories = FFmpegLocator.searchDirectories(
            bundle: .main,
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin"]
        )
        let homebrew = try? XCTUnwrap(directories.firstIndex(of: "/opt/homebrew/bin"))
        let usrBin = try? XCTUnwrap(directories.firstIndex(of: "/usr/bin"))
        XCTAssertNotNil(homebrew)
        XCTAssertNotNil(usrBin)
        XCTAssertLessThan(homebrew ?? .max, usrBin ?? 0)
    }

    func testDeduplicatesDirectories() {
        let directories = FFmpegLocator.searchDirectories(
            bundle: .main,
            environment: ["PATH": "/opt/homebrew/bin:/opt/homebrew/bin"]
        )
        XCTAssertEqual(directories.filter { $0 == "/opt/homebrew/bin" }.count, 1)
    }

    func testMissingToolThrowsWithSearchedPaths() {
        XCTAssertThrowsError(
            try FFmpegLocator.find("definitely-not-a-tool", in: ["/nowhere"], fileManager: .default)
        ) { error in
            guard case let UpscaleError.toolNotFound(tool, searched) = error else {
                return XCTFail("expected toolNotFound, got \(error)")
            }
            XCTAssertEqual(tool, "definitely-not-a-tool")
            XCTAssertEqual(searched, ["/nowhere"])
        }
    }
}
