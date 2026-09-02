import Metal
import XCTest
@testable import UpscaleCore

/// The colour conversion moved from ffmpeg's scaler into Metal, so it has to agree with
/// what the scaler produced — otherwise every output would be tinted or shifted.
final class ColorConversionTests: XCTestCase {
    private let width = 320
    private let height = 240

    private func requireDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available.")
        }
        return device
    }

    private func properties(matrix: String, range: String) -> ColorProperties {
        ColorProperties(matrix: matrix, range: range, primaries: "bt709", transfer: "bt709")
    }

    // MARK: - YUV to RGB

    /// `testsrc2` is the worst case for this comparison: hard, saturated colour edges,
    /// where the whole difference is chroma upsampling rather than the matrices. For
    /// scale, ffmpeg's own two chroma paths on this frame — the direct `yuv420p→rgb24`
    /// conversion against going through `yuv444p` first — differ by 7.2/255, more than
    /// three times what our bilinear upsample differs from either. The tight bound is
    /// the photographic case below.
    func testYUVToRGBMatchesFFmpegForEveryMatrixAndRange() throws {
        let tools = try TestSupport.requireTools()
        let device = try requireDevice()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let yuv = try makeYUVSource(tools: tools, in: directory)

        for (matrix, range) in [("bt709", "tv"), ("bt709", "pc"), ("bt470bg", "tv")] {
            let reference = try ffmpegYUVToRGB(
                yuv, tools: tools, matrix: matrix, range: range, in: directory
            )
            let ours = try metalYUVToRGB(
                yuv, device: device, color: properties(matrix: matrix, range: range)
            )
            let difference = meanAbsoluteDifference(ours, reference)
            print("yuv420p->rgb \(matrix)/\(range): \(difference)/255")
            XCTAssertLessThan(difference, 3.0, "\(matrix)/\(range)")
        }
    }

    /// On real content — the same 480p anime frame the golden test uses — chroma
    /// upsampling barely matters and only the matrices are left, so the conversion has
    /// to agree with ffmpeg closely.
    func testYUVToRGBMatchesFFmpegOnAPhotographicFrame() throws {
        let tools = try TestSupport.requireTools()
        let device = try requireDevice()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: "anime4k_source_640x480", withExtension: "png",
                subdirectory: "Fixtures"
            )
        )
        let yuv = directory.appendingPathComponent("anime.yuv")
        try run(
            tools.ffmpeg,
            [
                "-nostdin", "-v", "error", "-y", "-i", source.path,
                "-vf", "scale=out_color_matrix=bt709:out_range=tv",
                "-pix_fmt", "yuv420p", "-f", "rawvideo", yuv.path,
            ]
        )

        let planarFrame = try Data(contentsOf: yuv)
        let reference = try ffmpegYUVToRGB(
            planarFrame, tools: tools, matrix: "bt709", range: "tv", in: directory,
            width: 640, height: 480
        )
        let ours = try metalYUVToRGB(
            planarFrame, device: device, color: properties(matrix: "bt709", range: "tv"),
            width: 640, height: 480
        )
        let difference = meanAbsoluteDifference(ours, reference)
        print("yuv420p->rgb anime frame bt709/tv: \(difference)/255")
        // Measured at 1.47/255 on the development machine; the bound leaves room for a
        // different ffmpeg build without letting a real matrix error through, which
        // would show up as tens of levels, not one.
        XCTAssertLessThan(difference, 2.0)
    }

    // MARK: - RGB to YUV

    func testRGBToYUVMatchesFFmpegForEveryMatrixAndRange() throws {
        let tools = try TestSupport.requireTools()
        let device = try requireDevice()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rgb = try makeRGBSource(tools: tools, in: directory)

        for (matrix, range) in [("bt709", "tv"), ("bt709", "pc"), ("bt470bg", "tv")] {
            let reference = try ffmpegRGBToYUV(
                rgb, tools: tools, matrix: matrix, range: range, in: directory
            )
            let ours = try metalRGBToYUV(
                rgb, device: device, color: properties(matrix: matrix, range: range)
            )
            XCTAssertEqual(ours.count, reference.count)
            let difference = meanAbsoluteDifference(ours, reference)
            print("rgb->yuv420p \(matrix)/\(range): \(difference)/255")
            XCTAssertLessThan(difference, 1.5, "\(matrix)/\(range)")
        }
    }

    /// The two transforms are each other's inverse, so a full round trip through both
    /// kernels has to come back where it started apart from chroma subsampling.
    func testTransformsAreInverses() {
        for (matrix, range) in [("bt709", "tv"), ("bt709", "pc"), ("bt470bg", "tv"), ("bt2020nc", "tv")] {
            let transforms = properties(matrix: matrix, range: range).metalTransforms()
            for rgb in [SIMD3<Float>(0, 0, 0), SIMD3(1, 1, 1), SIMD3(0.2, 0.7, 0.4)] {
                let yuv = transforms.toYUV.applyAddingOffset(rgb)
                let back = transforms.toRGB.applySubtractingOffset(yuv)
                for channel in 0..<3 {
                    XCTAssertEqual(back[channel], rgb[channel], accuracy: 1e-4, "\(matrix)/\(range)")
                }
            }
        }
    }

    // MARK: - Fixtures

    /// One frame of `testsrc2` as planar 4:2:0, which is what comes off the decode pipe.
    private func makeYUVSource(tools: FFmpegTools, in directory: URL) throws -> Data {
        let url = directory.appendingPathComponent("source.yuv")
        try run(
            tools.ffmpeg,
            [
                "-nostdin", "-v", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=\(width)x\(height)",
                "-frames:v", "1", "-pix_fmt", "yuv420p", "-f", "rawvideo", url.path,
            ]
        )
        return try Data(contentsOf: url)
    }

    private func makeRGBSource(tools: FFmpegTools, in directory: URL) throws -> Data {
        let url = directory.appendingPathComponent("source.rgb")
        try run(
            tools.ffmpeg,
            [
                "-nostdin", "-v", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=\(width)x\(height)",
                "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", url.path,
            ]
        )
        return try Data(contentsOf: url)
    }

    private func ffmpegYUVToRGB(
        _ yuv: Data,
        tools: FFmpegTools,
        matrix: String,
        range: String,
        in directory: URL,
        width: Int? = nil,
        height: Int? = nil
    ) throws -> [UInt8] {
        let width = width ?? self.width
        let height = height ?? self.height
        let input = directory.appendingPathComponent("in-\(matrix)-\(range)-\(width).yuv")
        try yuv.write(to: input)
        let output = directory.appendingPathComponent("ref-\(matrix)-\(range)-\(width).rgb")
        try run(
            tools.ffmpeg,
            [
                "-nostdin", "-v", "error", "-y",
                "-f", "rawvideo", "-pix_fmt", "yuv420p",
                "-video_size", "\(width)x\(height)", "-i", input.path,
                "-vf", "scale=in_color_matrix=\(matrix):in_range=\(range):flags=full_chroma_int",
                "-pix_fmt", "rgb24", "-f", "rawvideo", output.path,
            ]
        )
        return [UInt8](try Data(contentsOf: output))
    }

    private func ffmpegRGBToYUV(
        _ rgb: Data, tools: FFmpegTools, matrix: String, range: String, in directory: URL
    ) throws -> [UInt8] {
        let input = directory.appendingPathComponent("in-\(matrix)-\(range).rgb")
        try rgb.write(to: input)
        let output = directory.appendingPathComponent("ref-\(matrix)-\(range).yuv")
        try run(
            tools.ffmpeg,
            [
                "-nostdin", "-v", "error", "-y",
                "-f", "rawvideo", "-pix_fmt", "rgb24",
                "-video_size", "\(width)x\(height)", "-i", input.path,
                "-vf", "scale=out_color_matrix=\(matrix):out_range=\(range)",
                "-pix_fmt", "yuv420p", "-f", "rawvideo", output.path,
            ]
        )
        return [UInt8](try Data(contentsOf: output))
    }

    // MARK: - Our kernels

    private func metalYUVToRGB(
        _ yuv: Data,
        device: MTLDevice,
        color: ColorProperties,
        width: Int? = nil,
        height: Int? = nil
    ) throws -> [UInt8] {
        let width = width ?? self.width
        let height = height ?? self.height
        let planes = try FrameTextures.makePlanes(device: device, width: width, height: height)
        try FrameTextures.upload(planar: yuv, to: planes)

        let destination = try FrameTextures.makeTexture(device: device, width: width, height: height)
        let pipeline = try makePipeline(
            device: device, source: ColorKernels.toRGBSource, name: ColorKernels.toRGBFunctionName
        )
        var transform = color.metalTransforms().toRGB

        try encode(device: device) { commandBuffer in
            let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(planes.luma, index: 0)
            encoder.setTexture(planes.chromaBlue, index: 1)
            encoder.setTexture(planes.chromaRed, index: 2)
            encoder.setTexture(destination, index: 3)
            encoder.setBytes(&transform, length: MemoryLayout<ColorTransform>.stride, index: 0)
            dispatch(encoder: encoder, pipeline: pipeline, width: width, height: height)
            encoder.endEncoding()
        }

        // The kernel writes BGRA; the reference is RGB24.
        let bgra = [UInt8](FrameTextures.readback(from: destination))
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3 + 0] = bgra[pixel * 4 + 2]
            rgb[pixel * 3 + 1] = bgra[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = bgra[pixel * 4 + 0]
        }
        return rgb
    }

    private func metalRGBToYUV(
        _ rgb: Data, device: MTLDevice, color: ColorProperties
    ) throws -> [UInt8] {
        // Upload RGB24 as BGRA, which is what the chain's resolve textures use.
        let source = try FrameTextures.makeTexture(device: device, width: width, height: height)
        var bgra = [UInt8](repeating: 255, count: width * height * 4)
        let rgbBytes = [UInt8](rgb)
        for pixel in 0..<(width * height) {
            bgra[pixel * 4 + 0] = rgbBytes[pixel * 3 + 2]
            bgra[pixel * 4 + 1] = rgbBytes[pixel * 3 + 1]
            bgra[pixel * 4 + 2] = rgbBytes[pixel * 3 + 0]
        }
        try FrameTextures.upload(Data(bgra), to: source)

        let planes = try FrameTextures.makePlanes(device: device, width: width, height: height)
        let pipeline = try makePipeline(
            device: device, source: ColorKernels.toYUVSource, name: ColorKernels.toYUVFunctionName
        )
        var transform = color.metalTransforms().toYUV

        try encode(device: device) { commandBuffer in
            let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(planes.luma, index: 1)
            encoder.setTexture(planes.chromaBlue, index: 2)
            encoder.setTexture(planes.chromaRed, index: 3)
            encoder.setBytes(&transform, length: MemoryLayout<ColorTransform>.stride, index: 0)
            dispatch(
                encoder: encoder, pipeline: pipeline,
                width: planes.chromaBlue.width, height: planes.chromaBlue.height
            )
            encoder.endEncoding()
        }

        var buffer = [UInt8](
            repeating: 0,
            count: RawFrameFormat.yuv420p.frameByteCount(width: width, height: height)
        )
        try buffer.withUnsafeMutableBytes { raw in
            try FrameTextures.readback(planes: planes, into: raw)
        }
        return buffer
    }

    // MARK: - Plumbing

    private func makePipeline(
        device: MTLDevice, source: String, name: String
    ) throws -> MTLComputePipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: name))
        return try device.makeComputePipelineState(function: function)
    }

    private func dispatch(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (width + threadWidth - 1) / threadWidth,
                height: (height + threadHeight - 1) / threadHeight,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }

    private func encode(device: MTLDevice, _ body: (MTLCommandBuffer) throws -> Void) throws {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try body(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
    }

    private func meanAbsoluteDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        precondition(lhs.count == rhs.count)
        var total = 0
        for index in lhs.indices {
            total += abs(Int(lhs[index]) - Int(rhs[index]))
        }
        return Double(total) / Double(lhs.count)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let result = try ProcessRunner.run(executable: executable, arguments: arguments)
        guard result.terminationStatus == 0 else {
            throw UpscaleError.processFailed(
                tool: "ffmpeg", status: result.terminationStatus, stderr: result.standardError
            )
        }
    }
}
