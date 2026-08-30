import Foundation

/// ffmpeg process #1: demuxes and decodes the input, writing raw frames to stdout.
public final class DecodeProcess {
    public let process: FFmpegProcess
    public let format: RawFrameFormat
    public let width: Int
    public let height: Int

    /// Bytes in one frame on the pipe — the exact size a reader consumes per frame.
    public var frameByteCount: Int { format.frameByteCount(width: width, height: height) }

    /// Raw frames arrive here.
    public var outputHandle: FileHandle? { process.outputHandle }

    public init(
        ffmpeg: URL,
        input: URL,
        media: MediaInfo,
        format: RawFrameFormat = .bgra
    ) {
        self.format = format
        self.width = media.video.width
        self.height = media.video.height
        self.process = FFmpegProcess(
            label: "ffmpeg (decode)",
            executable: ffmpeg,
            arguments: DecodeProcess.arguments(input: input, media: media, format: format),
            standardInput: .null,
            standardOutput: .pipe
        )
    }

    public static func arguments(
        input: URL,
        media: MediaInfo,
        format: RawFrameFormat
    ) -> [String] {
        [
            "-nostdin",
            "-v", "error",
            "-i", input.path,
            "-map", "0:v:0",
            // Normalise to constant frame rate at the stream's nominal rate. The encode
            // side is given the same rate, so frames read and frames written line up and
            // a variable-rate source cannot drift against its audio.
            "-fps_mode", "cfr",
            "-r", media.video.realFrameRate.ffmpegArgument,
            "-f", "rawvideo",
            "-pix_fmt", format.ffmpegName,
            "pipe:1",
        ]
    }

    public func start() throws { try process.start() }
    public func terminate() { process.terminate() }
    public var stderrTail: String { process.stderrTail }
    public func waitAndCheck() throws { try process.waitAndCheck() }
}
