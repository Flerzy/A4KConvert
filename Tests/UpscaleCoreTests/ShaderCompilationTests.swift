import Metal
import XCTest
@testable import UpscaleCore

/// WP2 acceptance: every shipped `.glsl` stage translates to MSL and compiles on the
/// host GPU, mirroring Anime4KMetal's own test approach.
final class ShaderCompilationTests: XCTestCase {
    private func requireDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available.")
        }
        return device
    }

    func testEveryShippedShaderCompiles() throws {
        let device = try requireDevice()
        let catalog = ShaderCatalog()
        var stageCount = 0

        for fileName in Preset.allShaderFiles {
            let stages = try catalog.stages(for: fileName)
            XCTAssertFalse(stages.isEmpty, "\(fileName) parsed to no stages")

            for stage in stages {
                stageCount += 1
                let source = MSLTranslator.metalSource(for: stage)
                do {
                    let library = try device.makeLibrary(source: source, options: nil)
                    XCTAssertNotNil(
                        library.makeFunction(name: stage.functionName),
                        "\(fileName): kernel \(stage.functionName) missing from library"
                    )
                } catch {
                    XCTFail("\(fileName) stage '\(stage.name)' failed to compile: \(error)")
                }
            }
        }

        // The four presets between them reference nine files; a silent resource-loading
        // regression would show up here as a much smaller number.
        XCTAssertEqual(Preset.allShaderFiles.count, 9)
        XCTAssertGreaterThan(stageCount, 50)
    }

    func testEveryShippedStageBuildsAPipelineState() throws {
        let device = try requireDevice()
        let catalog = ShaderCatalog()

        // One representative file per shape: statistics + PREKERNEL, a CNN, a resize.
        for fileName in ["Anime4K_Clamp_Highlights", "Anime4K_Upscale_CNN_x2_S",
                         "Anime4K_AutoDownscalePre_x2"] {
            for stage in try catalog.stages(for: fileName) {
                let library = try device.makeLibrary(
                    source: MSLTranslator.metalSource(for: stage), options: nil
                )
                let function = try XCTUnwrap(library.makeFunction(name: stage.functionName))
                XCTAssertNoThrow(try device.makeComputePipelineState(function: function))
            }
        }
    }

    func testTranslatedSourceThreadsTexturesThroughHelperFunctions() throws {
        let stage = try XCTUnwrap(
            try MPVShaderParser.parse(ShaderParserTests.fixture, fileName: "Fixture.glsl").first
        )
        let source = MSLTranslator.metalSource(for: stage)

        // The helper gains the position and every bound texture as parameters …
        XCTAssertTrue(
            source.contains(
                "float helper(float2 mtlPos, "
                    + "texture2d<float, access::sample> HOOKED, "
                    + "texture2d<float, access::sample> NATIVE, "
                    + "texture2d<float, access::sample> MAIN, vec4 rgba) {"
            ),
            source
        )
        // … and its call site passes them on.
        XCTAssertTrue(source.contains("helper(mtlPos, HOOKED, NATIVE, MAIN, HOOKED_texOff"), source)
        // A no-argument definition must not be left with a dangling comma.
        XCTAssertTrue(
            source.contains(
                "vec4 hook(float2 mtlPos, "
                    + "texture2d<float, access::sample> HOOKED, "
                    + "texture2d<float, access::sample> NATIVE, "
                    + "texture2d<float, access::sample> MAIN) {"
            ),
            source
        )
        // mpv's accessors become macros over those parameters.
        XCTAssertTrue(source.contains("#define HOOKED_pt (vec2(1.0, 1.0) / HOOKED_size)"), source)
        // The kernel samples at pixel centres.
        XCTAssertTrue(source.contains("(float2(gid) + float2(0.5)) / float2(size)"), source)
    }

    func testFixtureShaderCompiles() throws {
        let device = try requireDevice()
        for stage in try MPVShaderParser.parse(ShaderParserTests.fixture, fileName: "Fixture.glsl") {
            let source = MSLTranslator.metalSource(for: stage)
            XCTAssertNoThrow(
                try device.makeLibrary(source: source, options: nil),
                "\(stage.name)\n\(source)"
            )
        }
    }
}
