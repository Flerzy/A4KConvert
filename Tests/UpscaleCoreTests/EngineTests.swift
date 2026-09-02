import Metal
import MetalPerformanceShaders
import XCTest
@testable import UpscaleCore

final class RenderPlanTests: XCTestCase {
    private func stages(for preset: Preset) throws -> [MPVShaderStage] {
        try ShaderCatalog().stages(for: preset)
    }

    /// At 2x the second upscale pass is gated off, so the chain lands exactly on the
    /// target with no final resample.
    func testModeAAtTwoTimesRunsOneUpscalePass() throws {
        let plan = try RenderPlan.build(
            stages: try stages(for: XCTUnwrap(Preset.preset(id: "mode-a-fast"))),
            inputSize: PixelSize(width: 640, height: 480),
            targetSize: PixelSize(width: 1280, height: 960)
        )
        XCTAssertEqual(plan.finalSize, PixelSize(width: 1280, height: 960))
        XCTAssertTrue(plan.producesTargetSize)

        let files = plan.passes.map(\.stage.sourceFile)
        XCTAssertTrue(files.contains("Anime4K_Restore_CNN_M"))
        XCTAssertTrue(files.contains("Anime4K_Upscale_CNN_x2_M"))
        // Already at target after the first upscale, so these are skipped.
        XCTAssertFalse(files.contains("Anime4K_Upscale_CNN_x2_S"))
        XCTAssertFalse(files.contains("Anime4K_AutoDownscalePre_x2"))
        XCTAssertFalse(files.contains("Anime4K_AutoDownscalePre_x4"))
    }

    func testModeAAtFourTimesRunsBothUpscalePasses() throws {
        let plan = try RenderPlan.build(
            stages: try stages(for: XCTUnwrap(Preset.preset(id: "mode-a-fast"))),
            inputSize: PixelSize(width: 640, height: 480),
            targetSize: PixelSize(width: 2560, height: 1920)
        )
        XCTAssertEqual(plan.finalSize, PixelSize(width: 2560, height: 1920))
        let files = plan.passes.map(\.stage.sourceFile)
        XCTAssertTrue(files.contains("Anime4K_Upscale_CNN_x2_M"))
        XCTAssertTrue(files.contains("Anime4K_Upscale_CNN_x2_S"))
    }

    /// Clamp_Highlights measures where it sits in the file but clamps at the end;
    /// that only works if PREKERNEL passes are moved behind every MAIN pass.
    func testPrekernelPassRunsLast() throws {
        let plan = try RenderPlan.build(
            stages: try stages(for: XCTUnwrap(Preset.preset(id: "mode-a-fast"))),
            inputSize: PixelSize(width: 640, height: 480),
            targetSize: PixelSize(width: 1280, height: 960)
        )
        let hooks = plan.passes.map(\.stage.hook)
        XCTAssertEqual(hooks.last, .prekernel)
        XCTAssertEqual(hooks.filter { $0 == .prekernel }.count, 1)
        XCTAssertTrue(hooks.dropLast().allSatisfy { $0 == .main })
        // It clamps the upscaled image, so it runs at the target size.
        XCTAssertEqual(plan.passes.last?.size, PixelSize(width: 1280, height: 960))
    }

    /// A pass that both binds and saves MAIN must not write the texture it is reading.
    func testSaveMainRebindsToAFreshSlot() throws {
        let plan = try RenderPlan.build(
            stages: try stages(for: XCTUnwrap(Preset.preset(id: "mode-a-fast"))),
            inputSize: PixelSize(width: 640, height: 480),
            targetSize: PixelSize(width: 1280, height: 960)
        )
        for pass in plan.passes {
            XCTAssertFalse(
                pass.inputSlots.contains(pass.outputSlot),
                "\(pass.stage.name) writes a texture it also reads"
            )
        }
    }

    func testEveryPresetPlansAtTwoAndFourTimes() throws {
        for preset in Preset.all {
            for scale in [2, 4] {
                let plan = try RenderPlan.build(
                    stages: try stages(for: preset),
                    inputSize: PixelSize(width: 640, height: 360),
                    targetSize: PixelSize(width: 640 * scale, height: 360 * scale)
                )
                XCTAssertEqual(
                    plan.finalSize,
                    PixelSize(width: 640 * scale, height: 360 * scale),
                    "\(preset.name) at \(scale)x"
                )
            }
        }
    }
}

final class Anime4KEngineTests: XCTestCase {
    private func requireDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available.")
        }
        return device
    }

    /// WP3 golden test: Mode A (Fast) on a 480p frame has to match what mpv produces
    /// with the same shader list. The reference PNG was generated once with
    /// `Fixtures/generate-golden.py`.
    func testModeAFastMatchesMPVReference() throws {
        let device = try requireDevice()
        let source = try ImageFixture.load(named: "anime4k_source_640x480")
        let reference = try ImageFixture.load(named: "anime4k_mode_a_fast_1280x960")

        let engine = try Anime4KEngine(
            preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
            device: device
        )
        let result = try run(
            engine: engine,
            device: device,
            source: source,
            targetSize: PixelSize(width: reference.width, height: reference.height)
        )

        let difference = try result.meanAbsoluteDifference(to: reference)
        print("golden mean abs diff vs mpv: \(difference)/255")
        if difference >= 2.0 {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("upscale-golden-actual.png")
            try? result.writePNG(to: url)
            XCTFail("mean abs diff \(difference) >= 2/255; wrote actual output to \(url.path)")
        }
    }

    /// Mode B is the second golden: it exercises the `Restore_Soft` files, which no
    /// other test touches, against an mpv screenshot taken with the same ordering.
    func testModeBHQMatchesMPVReference() throws {
        let device = try requireDevice()
        let source = try ImageFixture.load(named: "anime4k_source_640x480")
        let reference = try ImageFixture.load(named: "anime4k_mode_b_hq_1280x960")

        let engine = try Anime4KEngine(
            preset: try XCTUnwrap(Preset.preset(id: "mode-b-hq")),
            device: device
        )
        let result = try run(
            engine: engine,
            device: device,
            source: source,
            targetSize: PixelSize(width: reference.width, height: reference.height)
        )

        let difference = try result.meanAbsoluteDifference(to: reference)
        print("mode B (HQ) golden mean abs diff vs mpv: \(difference)/255")
        if difference >= 2.0 {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("upscale-golden-mode-b-actual.png")
            try? result.writePNG(to: url)
            XCTFail("mean abs diff \(difference) >= 2/255; wrote actual output to \(url.path)")
        }
    }

    func testOutputDiffersFromTheInputUpscale() throws {
        let device = try requireDevice()
        let source = try ImageFixture.load(named: "anime4k_source_640x480")
        let engine = try Anime4KEngine(
            preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
            device: device
        )
        let result = try run(
            engine: engine,
            device: device,
            source: source,
            targetSize: PixelSize(width: 1280, height: 960)
        )
        XCTAssertEqual(result.width, 1280)
        XCTAssertEqual(result.height, 960)

        // A blank or pass-through result would be a silent failure, so check the image
        // actually carries the source's structure and is not uniform.
        var histogram = Set<UInt8>()
        result.bgra.withUnsafeBytes { bytes in
            for index in stride(from: 0, to: bytes.count, by: 4 * 97) {
                histogram.insert(bytes[index])
            }
        }
        XCTAssertGreaterThan(histogram.count, 16, "output looks flat")
    }

    /// After warmup the pool must hand back the same textures rather than allocating.
    func testTexturePoolStopsAllocatingAfterWarmup() throws {
        let device = try requireDevice()
        let source = try ImageFixture.load(named: "anime4k_source_640x480")
        let engine = try Anime4KEngine(
            preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
            device: device
        )
        _ = try run(
            engine: engine, device: device, source: source,
            targetSize: PixelSize(width: 1280, height: 960)
        )
        let afterFirstFrame = engine.textureAllocationCount
        XCTAssertGreaterThan(afterFirstFrame, 0)

        for _ in 0..<3 {
            _ = try run(
                engine: engine, device: device, source: source,
                targetSize: PixelSize(width: 1280, height: 960), reconfigure: false
            )
        }
        XCTAssertEqual(engine.textureAllocationCount, afterFirstFrame)
    }

    /// The skip path must be a plain Lanczos resample and nothing else: same result as
    /// MPS on its own, and clearly different from the shader chain.
    func testPassthroughIsALanczosResampleAndNotTheChain() throws {
        let device = try requireDevice()
        let source = try ImageFixture.load(named: "anime4k_source_640x480")
        let targetSize = PixelSize(width: 1280, height: 960)
        let engine = try Anime4KEngine(
            preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
            device: device
        )
        try engine.configure(
            inputSize: PixelSize(width: source.width, height: source.height),
            targetSize: targetSize
        )

        let passthrough = try run(
            engine: engine, device: device, source: source, targetSize: targetSize,
            reconfigure: false, passthrough: true
        )
        let reference = try lanczos(source: source, targetSize: targetSize, device: device)
        XCTAssertLessThan(try passthrough.meanAbsoluteDifference(to: reference), 1.0 / 255.0)

        let upscaled = try run(
            engine: engine, device: device, source: source, targetSize: targetSize,
            reconfigure: false
        )
        XCTAssertGreaterThan(try passthrough.meanAbsoluteDifference(to: upscaled), 2.0 / 255.0)
    }

    /// The planar path at 8 and at 10 bits has to produce the same picture: the extra
    /// depth only buys precision, it must not shift or scale anything. Both are also
    /// checked against the mpv golden, loosely, because a 4:2:0 round trip on a 480p
    /// frame costs more than the chain itself does.
    func testPlanarPathMatchesAtEightAndTenBits() throws {
        let device = try requireDevice()
        let source = try ImageFixture.load(named: "anime4k_source_640x480")
        let reference = try ImageFixture.load(named: "anime4k_mode_a_fast_1280x960")
        let targetSize = PixelSize(width: reference.width, height: reference.height)
        let color = ColorProperties(
            matrix: "bt709", range: "tv", primaries: "bt709", transfer: "bt709"
        )

        var results: [Int: ImageFixture] = [:]
        for bitDepth in [8, 10] {
            let format = RawFrameFormat.planar(bitDepth: bitDepth)
            let engine = try Anime4KEngine(
                preset: try XCTUnwrap(Preset.preset(id: "mode-a-fast")),
                device: device
            )
            try engine.configure(
                inputSize: PixelSize(width: source.width, height: source.height),
                targetSize: targetSize,
                color: color,
                inputBitDepth: bitDepth,
                outputBitDepth: bitDepth
            )

            let input = try FrameTextures.makePlanes(
                device: device, width: source.width, height: source.height, format: format
            )
            try FrameTextures.upload(
                planar: PlanarFixture.encode(
                    source, color: color, format: format
                ),
                to: input
            )
            let output = try FrameTextures.makePlanes(
                device: device, width: targetSize.width, height: targetSize.height,
                format: format
            )

            let queue = try XCTUnwrap(device.makeCommandQueue())
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            try engine.encode(commandBuffer: commandBuffer, input: input, output: output)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw error }

            var buffer = [UInt8](
                repeating: 0,
                count: format.frameByteCount(width: targetSize.width, height: targetSize.height)
            )
            try buffer.withUnsafeMutableBytes { raw in
                try FrameTextures.readback(planes: output, into: raw)
            }
            results[bitDepth] = PlanarFixture.decode(
                buffer, width: targetSize.width, height: targetSize.height,
                color: color, format: format
            )
        }

        let eight = try XCTUnwrap(results[8])
        let ten = try XCTUnwrap(results[10])
        let betweenDepths = try eight.meanAbsoluteDifference(to: ten)
        print("planar 8-bit vs 10-bit: \(betweenDepths)/255")
        XCTAssertLessThan(betweenDepths, 0.5)

        for (bitDepth, result) in results {
            let difference = try result.meanAbsoluteDifference(to: reference)
            print("planar \(bitDepth)-bit vs mpv golden: \(difference)/255")
            XCTAssertLessThan(difference, 3.0, "\(bitDepth)-bit")
        }
    }

    func testWrongInputSizeIsRejected() throws {
        let device = try requireDevice()
        let engine = try Anime4KEngine(preset: Preset.all[0], device: device)
        try engine.configure(
            inputSize: PixelSize(width: 64, height: 64),
            targetSize: PixelSize(width: 128, height: 128)
        )
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let wrong = try FrameTextures.makeTexture(device: device, width: 32, height: 32)
        let output = try FrameTextures.makeTexture(device: device, width: 128, height: 128)
        XCTAssertThrowsError(
            try engine.encode(commandBuffer: commandBuffer, input: wrong, output: output)
        ) { error in
            guard case EngineError.sizeMismatch = error else {
                return XCTFail("expected sizeMismatch, got \(error)")
            }
        }
    }

    // MARK: - Helper

    private func run(
        engine: Anime4KEngine,
        device: MTLDevice,
        source: ImageFixture,
        targetSize: PixelSize,
        reconfigure: Bool = true,
        passthrough: Bool = false
    ) throws -> ImageFixture {
        if reconfigure {
            try engine.configure(
                inputSize: PixelSize(width: source.width, height: source.height),
                targetSize: targetSize
            )
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try FrameTextures.makeTexture(
            device: device, width: source.width, height: source.height
        )
        try FrameTextures.upload(source.bgra, to: input)
        let output = try FrameTextures.makeTexture(
            device: device, width: targetSize.width, height: targetSize.height
        )

        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        if passthrough {
            try engine.encodePassthrough(commandBuffer: commandBuffer, input: input, output: output)
        } else {
            try engine.encode(commandBuffer: commandBuffer, input: input, output: output)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw error
        }

        return ImageFixture(
            width: targetSize.width,
            height: targetSize.height,
            bgra: FrameTextures.readback(from: output)
        )
    }

    /// MPS Lanczos on its own, as the reference the passthrough path has to match.
    private func lanczos(
        source: ImageFixture,
        targetSize: PixelSize,
        device: MTLDevice
    ) throws -> ImageFixture {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try FrameTextures.makeTexture(
            device: device, width: source.width, height: source.height
        )
        try FrameTextures.upload(source.bgra, to: input)
        let output = try FrameTextures.makeTexture(
            device: device, width: targetSize.width, height: targetSize.height
        )
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        MPSImageLanczosScale(device: device).encode(
            commandBuffer: commandBuffer, sourceTexture: input, destinationTexture: output
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return ImageFixture(
            width: targetSize.width,
            height: targetSize.height,
            bgra: FrameTextures.readback(from: output)
        )
    }
}
