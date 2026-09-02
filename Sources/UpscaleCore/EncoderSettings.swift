import Foundation

/// The video encoders this build offers. Both are VideoToolbox, i.e. the Apple Silicon
/// media engine; software encoders are deferred.
public enum VideoEncoder: String, CaseIterable, Sendable {
    case hevc = "hevc_videotoolbox"
    case h264 = "h264_videotoolbox"

    public var displayName: String {
        switch self {
        case .hevc: return "HEVC (VideoToolbox)"
        case .h264: return "H.264 (VideoToolbox)"
        }
    }

    /// QuickTime refuses HEVC in MP4/MOV tagged `hev1`, so it gets `hvc1` there.
    /// Matroska has no such requirement.
    func videoTag(for container: OutputContainer) -> String? {
        guard self == .hevc, container != .matroska else { return nil }
        return "hvc1"
    }

    /// VideoToolbox has no 10-bit H.264 encoder, so 10-bit output is HEVC only.
    public var supportsTenBit: Bool { self == .hevc }

    /// The pixel format the encoder is fed. VideoToolbox's 10-bit path is `p010le`,
    /// the semi-planar 10-in-16-bit format the media engine takes.
    public func encodePixelFormat(bitDepth: Int) -> String {
        bitDepth >= 10 && supportsTenBit ? "p010le" : "yuv420p"
    }
}

/// Encoder choice plus its quality knob and output depth.
public struct EncoderSettings: Equatable, Sendable {
    public var encoder: VideoEncoder
    /// VideoToolbox constant quality, 1...100, higher is better. Maps to `-q:v`.
    public var quality: Int
    /// Bits per sample in the written file: 8, or 10 for HEVC.
    public var outputBitDepth: Int

    public static let defaultQuality = 65

    public init(
        encoder: VideoEncoder = .hevc,
        quality: Int = EncoderSettings.defaultQuality,
        outputBitDepth: Int = 8
    ) {
        self.encoder = encoder
        self.quality = min(100, max(1, quality))
        self.outputBitDepth = outputBitDepth == 10 ? 10 : 8
    }

    /// The depth that is actually written: 10-bit falls back to 8 for encoders that
    /// cannot carry it, and the job refuses the combination before it starts.
    public var effectiveBitDepth: Int {
        outputBitDepth >= 10 && encoder.supportsTenBit ? 10 : 8
    }

    public func arguments(for container: OutputContainer) -> [String] {
        var arguments = ["-c:v", encoder.rawValue, "-q:v", String(quality)]
        arguments += ["-pix_fmt", encoder.encodePixelFormat(bitDepth: outputBitDepth)]
        if outputBitDepth >= 10, encoder.supportsTenBit {
            arguments += ["-profile:v", "main10"]
        }
        if let tag = encoder.videoTag(for: container) {
            arguments += ["-tag:v", tag]
        }
        return arguments
    }
}
