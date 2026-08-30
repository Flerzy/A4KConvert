import Metal
import XCTest
@testable import UpscaleCore

/// WP3 benchmark. Not CI-gating: it reports a rate rather than asserting one, because
/// the useful number depends entirely on the machine.
///
/// Run with `UPSCALE_BENCHMARK=1 swift test --filter EngineBenchmarkTests`.
final class EngineBenchmarkTests: XCTestCase {
    func testReports1080pToFourKThroughput() throws {
        guard ProcessInfo.processInfo.environment["UPSCALE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set UPSCALE_BENCHMARK=1 to run the throughput benchmark.")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available.")
        }

        let input = PixelSize(width: 1920, height: 1080)
        let target = PixelSize(width: 3840, height: 2160)
        let queue = try XCTUnwrap(device.makeCommandQueue())

        for preset in Preset.all {
            let engine = try Anime4KEngine(preset: preset, device: device)

            let compileStart = Date()
            try engine.configure(inputSize: input, targetSize: target)
            let compileSeconds = Date().timeIntervalSince(compileStart)

            let inputTexture = try FrameTextures.makeTexture(
                device: device, width: input.width, height: input.height
            )
            let outputTexture = try FrameTextures.makeTexture(
                device: device, width: target.width, height: target.height
            )

            // Warm up so the first frame's allocations are not counted.
            let warmup = try XCTUnwrap(queue.makeCommandBuffer())
            try engine.encode(commandBuffer: warmup, input: inputTexture, output: outputTexture)
            warmup.commit()
            warmup.waitUntilCompleted()

            let frames = 12
            let start = Date()
            // Two frames in flight, as the job runs them.
            var inFlight: [MTLCommandBuffer] = []
            for _ in 0..<frames {
                let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                try engine.encode(
                    commandBuffer: commandBuffer, input: inputTexture, output: outputTexture
                )
                commandBuffer.commit()
                inFlight.append(commandBuffer)
                if inFlight.count == 2 {
                    inFlight.removeFirst().waitUntilCompleted()
                }
            }
            for commandBuffer in inFlight {
                commandBuffer.waitUntilCompleted()
            }
            let seconds = Date().timeIntervalSince(start)

            print(String(
                format: "%@ 1080p->4K: %.2f fps (%.1f ms/frame), %d passes, "
                    + "%d textures, %.1fs to compile",
                preset.name,
                Double(frames) / seconds,
                seconds / Double(frames) * 1000,
                engine.renderPlan?.passes.count ?? 0,
                engine.textureAllocationCount,
                compileSeconds
            ))
        }
    }
}
