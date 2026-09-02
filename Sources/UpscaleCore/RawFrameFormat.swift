import Foundation

/// The raw pixel layout carried over the pipes between ffmpeg and Metal.
///
/// The job runs `yuv420p`: at 4K that is 12 MB a frame instead of the 33 MB packed BGRA
/// costs, and the colour conversion happens in Metal at both ends. `bgra` stays for the
/// RGB-in/RGB-out paths — the golden tests and the preview — where a packed frame is
/// what the caller already has.
public struct RawFrameFormat: Equatable, Sendable {
    public enum Layout: Equatable, Sendable {
        /// One interleaved plane of `bytesPerPixel` bytes per pixel.
        case packed(bytesPerPixel: Int)
        /// Y at full size, then Cb and Cr at half width and half height.
        case planar420(bytesPerSample: Int)
    }

    /// One plane's position in the contiguous frame buffer.
    public struct Plane: Equatable, Sendable {
        public let offset: Int
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int
        public var byteCount: Int { bytesPerRow * height }
    }

    /// The name ffmpeg knows it by, for `-pix_fmt`.
    public let ffmpegName: String
    public let layout: Layout

    public static let bgra = RawFrameFormat(ffmpegName: "bgra", layout: .packed(bytesPerPixel: 4))
    public static let yuv420p = RawFrameFormat(
        ffmpegName: "yuv420p", layout: .planar420(bytesPerSample: 1)
    )
    /// 10-bit samples in the low bits of little-endian 16-bit words, which is how
    /// ffmpeg writes every `…10le` planar format.
    public static let yuv420p10le = RawFrameFormat(
        ffmpegName: "yuv420p10le", layout: .planar420(bytesPerSample: 2)
    )

    /// The planar format for a source or output of this depth.
    public static func planar(bitDepth: Int) -> RawFrameFormat {
        bitDepth >= 10 ? .yuv420p10le : .yuv420p
    }

    /// Bits per sample the pipe carries: 8, or 10 in 16-bit words.
    public var bitDepth: Int {
        switch layout {
        case .packed: return 8
        case let .planar420(bytesPerSample): return bytesPerSample >= 2 ? 10 : 8
        }
    }

    public var isPlanar: Bool {
        if case .planar420 = layout { return true }
        return false
    }

    public func frameByteCount(width: Int, height: Int) -> Int {
        planeLayout(width: width, height: height).reduce(0) { $0 + $1.byteCount }
    }

    /// Where each plane sits in one frame's bytes.
    ///
    /// ffmpeg writes rawvideo planes tightly packed with no row padding, so a plane's
    /// stride is its own width times the sample size.
    public func planeLayout(width: Int, height: Int) -> [Plane] {
        switch layout {
        case let .packed(bytesPerPixel):
            return [
                Plane(
                    offset: 0, width: width, height: height,
                    bytesPerRow: width * bytesPerPixel
                )
            ]
        case let .planar420(bytesPerSample):
            // Chroma is half resolution in both directions, rounded up so an odd size
            // still describes every sample ffmpeg writes.
            let chromaWidth = (width + 1) / 2
            let chromaHeight = (height + 1) / 2
            let luma = Plane(
                offset: 0, width: width, height: height, bytesPerRow: width * bytesPerSample
            )
            let cb = Plane(
                offset: luma.byteCount, width: chromaWidth, height: chromaHeight,
                bytesPerRow: chromaWidth * bytesPerSample
            )
            let cr = Plane(
                offset: cb.offset + cb.byteCount, width: chromaWidth, height: chromaHeight,
                bytesPerRow: chromaWidth * bytesPerSample
            )
            return [luma, cb, cr]
        }
    }
}
