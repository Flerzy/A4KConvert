import Foundation

/// The kind of an elementary stream, as reported by ffprobe's `codec_type`.
public enum StreamKind: String, Codable, Sendable {
    case video
    case audio
    case subtitle
    case attachment
    case data
}

/// A non-video stream we only ever pass through to the output container.
public struct MediaStream: Equatable, Sendable {
    public let index: Int
    public let kind: StreamKind
    public let codec: String
    public let language: String?
    public let title: String?
    public let channels: Int?
    public let isDefault: Bool

    public init(
        index: Int,
        kind: StreamKind,
        codec: String,
        language: String? = nil,
        title: String? = nil,
        channels: Int? = nil,
        isDefault: Bool = false
    ) {
        self.index = index
        self.kind = kind
        self.codec = codec
        self.language = language
        self.title = title
        self.channels = channels
        self.isDefault = isDefault
    }
}

/// The video stream the pipeline actually processes.
public struct VideoStream: Equatable, Sendable {
    public let index: Int
    public let codec: String
    public let width: Int
    public let height: Int
    public let pixelFormat: String
    public let bitDepth: Int
    /// The stream's nominal (constant) frame rate — what we hand back to ffmpeg.
    public let realFrameRate: Rational
    /// Frames divided by duration; differs from `realFrameRate` for VFR sources.
    public let averageFrameRate: Rational
    public let sampleAspectRatio: Rational
    public let nominalFrameCount: Int?
    public let duration: Double?
    public let colorRange: String?
    public let colorSpace: String?
    public let colorPrimaries: String?
    public let colorTransfer: String?

    public init(
        index: Int,
        codec: String,
        width: Int,
        height: Int,
        pixelFormat: String,
        bitDepth: Int,
        realFrameRate: Rational,
        averageFrameRate: Rational,
        sampleAspectRatio: Rational,
        nominalFrameCount: Int?,
        duration: Double?,
        colorRange: String?,
        colorSpace: String?,
        colorPrimaries: String?,
        colorTransfer: String?
    ) {
        self.index = index
        self.codec = codec
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.bitDepth = bitDepth
        self.realFrameRate = realFrameRate
        self.averageFrameRate = averageFrameRate
        self.sampleAspectRatio = sampleAspectRatio
        self.nominalFrameCount = nominalFrameCount
        self.duration = duration
        self.colorRange = colorRange
        self.colorSpace = colorSpace
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
    }

    /// True when the pixels are not square, which 2x scaling alone would distort.
    public var isAnamorphic: Bool {
        let sar = sampleAspectRatio.reduced
        guard sar.numerator > 0, sar.denominator > 0 else { return false }
        return sar.numerator != sar.denominator
    }
}

/// A container chapter, as ffprobe reports it.
public struct Chapter: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let title: String?

    public init(start: Double, end: Double, title: String?) {
        self.start = start
        self.end = end
        self.title = title
    }
}

/// Everything the pipeline needs to know about an input file.
public struct MediaInfo: Equatable, Sendable {
    public let path: String
    /// ffprobe's comma-separated `format_name`, e.g. `"matroska,webm"`.
    public let formatName: String
    public let duration: Double?
    public let video: VideoStream
    public let audioStreams: [MediaStream]
    public let subtitleStreams: [MediaStream]
    public let attachmentStreams: [MediaStream]
    public let chapters: [Chapter]

    public init(
        path: String,
        formatName: String,
        duration: Double?,
        video: VideoStream,
        audioStreams: [MediaStream],
        subtitleStreams: [MediaStream],
        attachmentStreams: [MediaStream],
        chapters: [Chapter] = []
    ) {
        self.path = path
        self.formatName = formatName
        self.duration = duration
        self.video = video
        self.audioStreams = audioStreams
        self.subtitleStreams = subtitleStreams
        self.attachmentStreams = attachmentStreams
        self.chapters = chapters
    }

    /// Best available frame count: the container's own number when it has one,
    /// otherwise duration times the nominal frame rate.
    ///
    /// Matroska usually stores neither a frame count nor a per-stream duration, so
    /// the estimate is what progress reporting has to run on for MKV input.
    public var estimatedFrameCount: Int? {
        if let nominal = video.nominalFrameCount, nominal > 0 { return nominal }
        guard let seconds = video.duration ?? duration, seconds > 0 else { return nil }
        let rate = video.realFrameRate.doubleValue
        guard rate > 0 else { return nil }
        return Int((seconds * rate).rounded())
    }

    /// 8- and 10-bit SDR are processed; anything else is refused rather than mangled.
    ///
    /// The shaders were trained on SDR, so HDR transfers and BT.2020 primaries stay out
    /// regardless of depth, and 12-bit has no plane format on the pipes.
    public func rejectionReason() -> String? {
        if video.bitDepth != 8, video.bitDepth != 10 {
            return "\(video.bitDepth)-bit video (\(video.pixelFormat)) is not supported — "
                + "only 8- and 10-bit SDR input."
        }
        if let transfer = video.colorTransfer, MediaInfo.hdrTransfers.contains(transfer) {
            return "HDR transfer function '\(transfer)' is not supported."
        }
        if let primaries = video.colorPrimaries, primaries == "bt2020" {
            return "BT.2020 primaries are not supported."
        }
        return nil
    }

    static let hdrTransfers: Set<String> = ["smpte2084", "arib-std-b67", "smpte428", "bt2020-10", "bt2020-12"]
}

/// Derives a bit depth from an ffmpeg pixel-format name.
///
/// ffmpeg spells depth as a suffix on the component layout: `yuv420p10le` is 10-bit,
/// `yuv420p` is 8-bit, `gbrp12be` is 12-bit.
public func bitDepth(forPixelFormat pixelFormat: String) -> Int {
    var digits = ""
    var scan = Substring(pixelFormat)
    if scan.hasSuffix("le") || scan.hasSuffix("be") {
        scan = scan.dropLast(2)
    }
    while let last = scan.last, last.isNumber {
        digits.insert(last, at: digits.startIndex)
        scan = scan.dropLast()
    }
    // A trailing number that is part of the chroma layout (yuv420p, nv12) is not a depth.
    guard !digits.isEmpty, let value = Int(digits), scan.last == "p" || scan.last == "x" else {
        return 8
    }
    return (8...16).contains(value) ? value : 8
}
