import Foundation

/// Everything the encode command needs that is not already in `MediaInfo`.
public struct EncodePlan: Equatable, Sendable {
    /// Geometry of the processed frames arriving on stdin.
    public var width: Int
    public var height: Int
    public var format: RawFrameFormat
    public var frameRate: Rational
    public var sampleAspectRatio: Rational
    public var color: ColorProperties
    public var settings: EncoderSettings
    public var container: OutputContainer

    public init(
        width: Int,
        height: Int,
        format: RawFrameFormat = .bgra,
        frameRate: Rational,
        sampleAspectRatio: Rational = .one,
        color: ColorProperties,
        settings: EncoderSettings = EncoderSettings(),
        container: OutputContainer
    ) {
        self.width = width
        self.height = height
        self.format = format
        self.frameRate = frameRate
        self.sampleAspectRatio = sampleAspectRatio
        self.color = color
        self.settings = settings
        self.container = container
    }

    /// Derives the plan for an upscale of `media` by `scale`.
    public static func make(
        for media: MediaInfo,
        scale: Int,
        settings: EncoderSettings,
        container: OutputContainer,
        format: RawFrameFormat = .bgra
    ) -> EncodePlan {
        EncodePlan(
            width: media.video.width * scale,
            height: media.video.height * scale,
            format: format,
            frameRate: media.video.realFrameRate,
            // Uniform scaling leaves the pixel aspect ratio unchanged, so carrying the
            // source SAR through keeps an anamorphic file displaying at the right shape.
            sampleAspectRatio: media.video.sampleAspectRatio,
            color: ColorProperties.from(media.video),
            settings: settings,
            container: container
        )
    }
}

/// ffmpeg process #2: takes processed raw frames on stdin, muxes them with the
/// original file's other streams, and writes the output.
public final class EncodeProcess {
    public let process: FFmpegProcess
    public let plan: EncodePlan

    /// Processed frames are written here.
    public var inputHandle: FileHandle? { process.inputHandle }

    public var frameByteCount: Int {
        plan.format.frameByteCount(width: plan.width, height: plan.height)
    }

    public init(
        ffmpeg: URL,
        source: URL,
        media: MediaInfo,
        output: URL,
        plan: EncodePlan
    ) {
        self.plan = plan
        self.process = FFmpegProcess(
            label: "ffmpeg (encode)",
            executable: ffmpeg,
            arguments: EncodeProcess.arguments(
                source: source,
                media: media,
                output: output,
                plan: plan
            ),
            standardInput: .pipe,
            standardOutput: .null
        )
    }

    /// yuv420p needs even dimensions; 2x of any size is even, but a custom target
    /// size could still land on an odd number, and that has to fail loudly.
    public static func validate(_ plan: EncodePlan) throws {
        guard plan.width % 2 == 0, plan.height % 2 == 0 else {
            throw UpscaleError.unsupportedInput(
                reason: "output size \(plan.width)x\(plan.height) is odd; "
                    + "4:2:0 encoding needs even width and height."
            )
        }
    }

    public static func arguments(
        source: URL,
        media: MediaInfo,
        output: URL,
        plan: EncodePlan
    ) -> [String] {
        var arguments = [
            "-nostdin",
            "-v", "error",
            // -nostats silences ffmpeg's own rewriting status line so that stderr
            // carries only log lines and the -progress records.
            "-nostats",
            "-progress", "pipe:2",
            "-y",
            // Input 0: the processed frames, which carry no metadata of their own.
            "-f", "rawvideo",
            "-pixel_format", plan.format.ffmpegName,
            "-video_size", "\(plan.width)x\(plan.height)",
            "-framerate", plan.frameRate.ffmpegArgument,
            "-i", "pipe:0",
            // Input 1: the original file, purely as the source of the other streams.
            "-i", source.path,
            "-map", "0:v:0",
        ]

        if !media.audioStreams.isEmpty {
            arguments += ["-map", "1:a?", "-c:a", "copy"]
        }

        arguments += subtitleArguments(for: media, container: plan.container)

        if plan.container.supportsAttachments, !media.attachmentStreams.isEmpty {
            arguments += ["-map", "1:t?"]
        }

        arguments += [
            "-map_metadata", "1",
            "-map_chapters", "1",
            // Never give up waiting for a sparse stream. Subtitle tracks go quiet for
            // minutes at a time, and past ffmpeg's default 10-second interleaving
            // window the muxer stops waiting and flushes audio ahead of the video —
            // on a feature-length file that puts the entire audio track in the first
            // few megabytes, so seeking anywhere past it finds no audio at all.
            // The cost is buffering until every stream has a packet: measured at
            // 236 MB of ffmpeg memory for a four-minute dialogue gap at 4K.
            "-max_interleave_delta", "0",
            "-vf", videoFilter(for: plan),
        ]
        arguments += plan.settings.arguments(for: plan.container)
        arguments += [
            "-r", plan.frameRate.ffmpegArgument,
            "-f", plan.container.ffmpegFormatName,
            output.path,
        ]
        return arguments
    }

    /// Maps the subtitle streams, with a codec per stream where they differ.
    ///
    /// Subtitles are kept only when every stream can be carried: dropping some but not
    /// others would quietly lose a track. Matroska legitimately needs two codecs at
    /// once — `mov_text` has to become SubRip while everything else is copied — so the
    /// codecs are spelled per stream rather than collapsed to one.
    static func subtitleArguments(for media: MediaInfo, container: OutputContainer) -> [String] {
        guard !media.subtitleStreams.isEmpty else { return [] }

        var codecs: [String] = []
        for stream in media.subtitleStreams {
            guard let codec = container.subtitleCodec(forSource: stream.codec) else { return [] }
            codecs.append(codec)
        }

        var arguments = ["-map", "1:s?"]
        if Set(codecs).count == 1 {
            arguments += ["-c:s", codecs[0]]
        } else {
            for (index, codec) in codecs.enumerated() {
                arguments += ["-c:s:\(index)", codec]
            }
        }
        return arguments
    }

    static func videoFilter(for plan: EncodePlan) -> String {
        var stages = [plan.color.rgbToYUVFilter(pixelFormat: plan.settings.encoder.encodePixelFormat)]
        let sar = plan.sampleAspectRatio.reduced
        if sar.numerator > 0, sar.denominator > 0 {
            stages.append("setsar=\(sar.numerator)/\(sar.denominator)")
        }
        stages.append(plan.color.setParametersFilter)
        return stages.joined(separator: ",")
    }

    public func start() throws {
        try EncodeProcess.validate(plan)
        try process.start()
    }

    public func closeInput() { process.closeInput() }
    public func terminate() { process.terminate() }
    public var stderrTail: String { process.stderrTail }
    public var progress: FFmpegProgress { process.progress }
    public var onProgress: ((FFmpegProgress) -> Void)? {
        get { process.onProgress }
        set { process.onProgress = newValue }
    }

    public func waitAndCheck() throws { try process.waitAndCheck() }
}
