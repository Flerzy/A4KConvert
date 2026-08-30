import Foundation

/// The video encoders v1 offers. Both are VideoToolbox, i.e. the Apple Silicon media
/// engine; software encoders are deferred.
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

    /// 8-bit 4:2:0 for both encoders — v1 does not process 10-bit input at all.
    var encodePixelFormat: String { "yuv420p" }
}

/// Encoder choice plus its one quality knob.
public struct EncoderSettings: Equatable, Sendable {
    public var encoder: VideoEncoder
    /// VideoToolbox constant quality, 1...100, higher is better. Maps to `-q:v`.
    public var quality: Int

    public static let defaultQuality = 65

    public init(encoder: VideoEncoder = .hevc, quality: Int = EncoderSettings.defaultQuality) {
        self.encoder = encoder
        self.quality = min(100, max(1, quality))
    }

    public func arguments(for container: OutputContainer) -> [String] {
        var arguments = ["-c:v", encoder.rawValue, "-q:v", String(quality)]
        if let tag = encoder.videoTag(for: container) {
            arguments += ["-tag:v", tag]
        }
        return arguments
    }
}
