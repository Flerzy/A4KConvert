import Metal
import XCTest
@testable import UpscaleCore

/// End-to-end throughput: decode, GPU chain, readback and encode together, which is
/// what the user actually waits for. Reports rather than asserts, like the engine
/// benchmark.
///
/// Run with `UPSCALE_BENCHMARK=1 swift test --filter JobBenchmarkTests`.
final class JobBenchmarkTests: XCTestCase {
    func testReports1080pToFourKJobThroughput() throws {
        guard ProcessInfo.processInfo.environment["UPSCALE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set UPSCALE_BENCHMARK=1 to run the job benchmark.")
        }
        let tools = try TestSupport.requireTools()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available.")
        }

        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var spec = TestSupport.FixtureSpec(width: 1920, height: 1080, durationSeconds: 5.0)
        spec.includeSubtitles = false
        let fixture = try TestSupport.makeFixture(spec, in: directory)

        let job = UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(
                preset: try XCTUnwrap(Preset.preset(id: "mode-aa-hq")),
                scale: 2,
                output: directory.appendingPathComponent("out.mkv")
            ),
            tools: tools,
            device: device
        )

        var last: UpscaleProgress?
        let start = Date()
        _ = try job.run { progress in
            if progress.phase == .processing { last = progress }
        }
        let wallClock = Date().timeIntervalSince(start)
        let progress = try XCTUnwrap(last)
        print(String(
            format: "Mode A+A (HQ) 1080p->4K end to end: %.2f fps (%d frames in %.1fs wall clock)",
            progress.framesPerSecond, progress.framesProcessed, wallClock
        ))
    }
}
