import XCTest
@testable import UpscaleCore

final class JobDefaultsTests: XCTestCase {
    private let input = URL(fileURLWithPath: "/videos/show/episode 1.mkv")

    func testSettingsWithoutAFolderWriteBesideTheInput() {
        let settings = JobDefaults.standard.settings(for: input)
        XCTAssertEqual(settings.output.path, "/videos/show/episode 1.2x.mkv")
        XCTAssertEqual(settings.preset, .default)
        XCTAssertEqual(settings.scale, 2)
        XCTAssertEqual(settings.encoder.encoder, .hevc)
        XCTAssertEqual(settings.encoder.quality, EncoderSettings.defaultQuality)
    }

    func testSettingsWithAFolderKeepTheNameAndChangeTheDirectory() {
        var defaults = JobDefaults.standard
        defaults.outputFolder = URL(fileURLWithPath: "/out", isDirectory: true)
        defaults.scale = 4
        XCTAssertEqual(defaults.settings(for: input).output.path, "/out/episode 1.4x.mkv")
    }

    /// The extension still follows the container we write, not the input's.
    func testFolderOutputStillRenamesToTheContainerWeWrite() {
        var defaults = JobDefaults.standard
        defaults.outputFolder = URL(fileURLWithPath: "/out", isDirectory: true)
        let settings = defaults.settings(for: URL(fileURLWithPath: "/v/clip.avi"))
        XCTAssertEqual(settings.output.path, "/out/clip.2x.mkv")
    }

    /// A preset id from an older build must not stop the defaults from loading.
    func testUnknownPresetIDFallsBackToTheDefaultPreset() {
        var defaults = JobDefaults.standard
        defaults.presetID = "mode-z-does-not-exist"
        XCTAssertEqual(defaults.preset, .default)
        XCTAssertEqual(defaults.settings(for: input).preset, .default)
    }

    func testEncoderAndQualityReachTheSettings() {
        var defaults = JobDefaults.standard
        defaults.encoder = .h264
        defaults.quality = 40
        let settings = defaults.settings(for: input)
        XCTAssertEqual(settings.encoder.encoder, .h264)
        XCTAssertEqual(settings.encoder.quality, 40)
    }
}
