import CoreGraphics
import Foundation
import Metal

/// Renders one frame twice — plainly resampled and through the preset — so the user can
/// judge a preset before committing to a forty-minute job.
///
/// Both images come back at the job's target size, so a viewer can put them side by
/// side or under a wipe divider at 1:1.
public enum FramePreview {
    public struct Result: Sendable {
        public let original: CGImage
        public let upscaled: CGImage
        /// The source time the frame was actually taken from.
        public let seconds: Double
    }

    /// Decodes the frame at `seconds` and runs it through the chain once.
    ///
    /// The frame crosses as packed BGRA rather than the planar format the job uses:
    /// there is one frame, the pipe cost is irrelevant, and the result goes straight
    /// into a `CGImage`. The chain itself is the same.
    public static func render(
        input: URL,
        at seconds: Double,
        settings: UpscaleJobSettings,
        media: MediaInfo? = nil,
        tools: FFmpegTools,
        device: MTLDevice,
        catalog: ShaderCatalog = ShaderCatalog()
    ) throws -> Result {
        let media = try media ?? Probe(tools: tools).probe(url: input)
        if let reason = media.rejectionReason() {
            throw UpscaleError.unsupportedInput(reason: reason)
        }

        let inputSize = PixelSize(width: media.video.width, height: media.video.height)
        let targetSize = PixelSize(
            width: media.video.width * settings.scale,
            height: media.video.height * settings.scale
        )
        let clamped = clamp(seconds: seconds, in: media)
        let frame = try decodeFrame(input: input, at: clamped, media: media, tools: tools)

        let engine = try Anime4KEngine(preset: settings.preset, device: device, catalog: catalog)
        try engine.configure(inputSize: inputSize, targetSize: targetSize)

        guard let queue = device.makeCommandQueue() else { throw EngineError.noMetalDevice }
        let source = try FrameTextures.makeTexture(
            device: device, width: inputSize.width, height: inputSize.height
        )
        try FrameTextures.upload(frame, to: source)
        let upscaled = try FrameTextures.makeTexture(
            device: device, width: targetSize.width, height: targetSize.height
        )
        let resampled = try FrameTextures.makeTexture(
            device: device, width: targetSize.width, height: targetSize.height
        )

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw EngineError.noMetalDevice
        }
        try engine.encode(commandBuffer: commandBuffer, input: source, output: upscaled)
        // The "before" side is the same Lanczos resample a skipped segment gets, so the
        // two images differ only by the chain.
        try engine.encodePassthrough(
            commandBuffer: commandBuffer, input: source, output: resampled
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }

        return Result(
            original: try makeImage(from: resampled),
            upscaled: try makeImage(from: upscaled),
            seconds: clamped
        )
    }

    /// Keeps the request inside the file, leaving a couple of frames at the end.
    ///
    /// Container durations are rounded, so seeking to exactly `duration - one frame`
    /// regularly lands past the last packet and decodes nothing at all.
    static func clamp(seconds: Double, in media: MediaInfo) -> Double {
        guard let duration = media.duration ?? media.video.duration, duration > 0 else {
            return max(0, seconds)
        }
        let frameDuration = 1 / max(media.video.realFrameRate.doubleValue, 1)
        return min(max(0, seconds), max(0, duration - 2 * frameDuration))
    }

    static func arguments(
        input: URL,
        at seconds: Double,
        media: MediaInfo,
        format: RawFrameFormat = .bgra
    ) -> [String] {
        [
            "-nostdin",
            "-v", "error",
            // Before -i, so ffmpeg seeks by keyframe instead of decoding from the start.
            "-ss", String(format: "%.3f", seconds),
            "-i", input.path,
            "-map", "0:v:0",
            "-frames:v", "1",
            "-f", "rawvideo",
            "-pix_fmt", format.ffmpegName,
            "pipe:1",
        ]
    }

    private static func decodeFrame(
        input: URL,
        at seconds: Double,
        media: MediaInfo,
        tools: FFmpegTools
    ) throws -> Data {
        let expected = RawFrameFormat.bgra.frameByteCount(
            width: media.video.width, height: media.video.height
        )

        // A seek very close to the end can still land past the last packet, so one
        // retry a second earlier stands between the user and an empty sheet.
        for attempt in [seconds, max(0, seconds - 1)] {
            let result = try ProcessRunner.run(
                executable: tools.ffmpeg,
                arguments: arguments(input: input, at: attempt, media: media)
            )
            guard result.terminationStatus == 0 else {
                throw UpscaleError.processFailed(
                    tool: "ffmpeg (preview)",
                    status: result.terminationStatus,
                    stderr: result.standardError
                )
            }
            if result.standardOutputData.count >= expected {
                return result.standardOutputData.prefix(expected)
            }
            if attempt == 0 { break }
        }

        throw UpscaleError.processFailed(
            tool: "ffmpeg (preview)",
            status: 0,
            stderr: "no frame at \(Timecode.format(seconds))"
        )
    }

    private static func makeImage(from texture: MTLTexture) throws -> CGImage {
        let bytesPerRow = texture.width * 4
        let data = FrameTextures.readback(from: texture)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw EngineError.notConfigured
        }
        // The textures are BGRA8; CoreGraphics spells that as little-endian 32-bit with
        // the alpha first.
        guard let image = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                .union(.byteOrder32Little),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw EngineError.textureAllocationFailed(width: texture.width, height: texture.height)
        }
        return image
    }
}
