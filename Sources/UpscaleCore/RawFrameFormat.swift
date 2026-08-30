import Foundation

/// The raw pixel layout carried over the pipes between ffmpeg and Metal.
///
/// v1 uses `bgra` only: it maps 1:1 onto `MTLPixelFormat.bgra8Unorm`, so no manual
/// YUV plane handling is needed. If the pipe ever becomes the bottleneck, the input
/// side moves to `yuv420p` with the conversion done as a Metal pass.
public struct RawFrameFormat: Equatable, Sendable {
    /// The name ffmpeg knows it by, for `-pix_fmt`.
    public let ffmpegName: String
    public let bytesPerPixel: Int

    public static let bgra = RawFrameFormat(ffmpegName: "bgra", bytesPerPixel: 4)

    public func frameByteCount(width: Int, height: Int) -> Int {
        width * height * bytesPerPixel
    }

    public func bytesPerRow(width: Int) -> Int {
        width * bytesPerPixel
    }
}
