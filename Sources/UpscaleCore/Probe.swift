import Foundation

/// Runs `ffprobe` and turns its JSON into a `MediaInfo`.
public struct Probe {
    private let ffprobe: URL

    public init(ffprobe: URL) {
        self.ffprobe = ffprobe
    }

    public init(tools: FFmpegTools) {
        self.init(ffprobe: tools.ffprobe)
    }

    public static func arguments(for url: URL) -> [String] {
        [
            "-v", "error",
            "-print_format", "json",
            "-show_streams",
            "-show_format",
            url.path,
        ]
    }

    public func probe(url: URL) throws -> MediaInfo {
        let result = try ProcessRunner.run(executable: ffprobe, arguments: Probe.arguments(for: url))
        guard result.terminationStatus == 0 else {
            throw UpscaleError.processFailed(
                tool: "ffprobe",
                status: result.terminationStatus,
                stderr: result.standardError
            )
        }
        return try Probe.parse(json: result.standardOutputData, path: url.path)
    }

    /// Split out from `probe(url:)` so tests can feed recorded ffprobe output.
    public static func parse(json: Data, path: String) throws -> MediaInfo {
        let output: FFprobeOutput
        do {
            output = try JSONDecoder().decode(FFprobeOutput.self, from: json)
        } catch {
            throw UpscaleError.probeFailed(reason: String(describing: error))
        }

        guard let rawVideo = output.streams.first(where: { $0.kind == .video }),
              let width = rawVideo.width, let height = rawVideo.height,
              width > 0, height > 0
        else {
            throw UpscaleError.noVideoStream(path: path)
        }

        let pixelFormat = rawVideo.pixelFormat ?? "yuv420p"
        let realFrameRate = rawVideo.realFrameRate.flatMap(Rational.parse) ?? Rational(25, 1)
        let averageFrameRate = rawVideo.averageFrameRate.flatMap(Rational.parse) ?? realFrameRate
        // ffprobe reports "0:1" for "unknown", which means square pixels in practice.
        let parsedSAR = rawVideo.sampleAspectRatio.flatMap(Rational.parse) ?? Rational.one
        let sampleAspectRatio = parsedSAR.numerator > 0 && parsedSAR.denominator > 0 ? parsedSAR : Rational.one

        let video = VideoStream(
            index: rawVideo.index,
            codec: rawVideo.codecName ?? "unknown",
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            bitDepth: rawVideo.bitsPerRawSample ?? bitDepth(forPixelFormat: pixelFormat),
            realFrameRate: realFrameRate.isZero ? Rational(25, 1) : realFrameRate,
            averageFrameRate: averageFrameRate,
            sampleAspectRatio: sampleAspectRatio,
            nominalFrameCount: rawVideo.frameCount,
            duration: rawVideo.duration,
            colorRange: rawVideo.colorRange,
            colorSpace: rawVideo.colorSpace,
            colorPrimaries: rawVideo.colorPrimaries,
            colorTransfer: rawVideo.colorTransfer
        )

        func streams(of kind: StreamKind) -> [MediaStream] {
            output.streams
                .filter { $0.kind == kind }
                .map { raw in
                    MediaStream(
                        index: raw.index,
                        kind: kind,
                        codec: raw.codecName ?? "unknown",
                        language: raw.tag("language"),
                        title: raw.tag("title"),
                        channels: raw.channels,
                        isDefault: raw.isDefault
                    )
                }
        }

        return MediaInfo(
            path: path,
            formatName: output.format?.formatName ?? "",
            duration: output.format?.duration,
            video: video,
            audioStreams: streams(of: .audio),
            subtitleStreams: streams(of: .subtitle),
            attachmentStreams: streams(of: .attachment)
        )
    }
}
