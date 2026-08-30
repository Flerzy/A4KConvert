import Foundation

/// Everything the user chooses about one conversion.
public struct UpscaleJobSettings: Equatable, Sendable {
    public var preset: Preset
    /// Integer upscale factor. 2 and 4 are what the UI offers; both keep the output
    /// dimensions even, which 4:2:0 encoding requires.
    public var scale: Int
    public var encoder: EncoderSettings
    /// The output container. `nil` keeps the input's own container.
    public var container: OutputContainer?
    public var output: URL

    public init(
        preset: Preset = .default,
        scale: Int = 2,
        encoder: EncoderSettings = EncoderSettings(),
        container: OutputContainer? = nil,
        output: URL
    ) {
        self.preset = preset
        self.scale = scale
        self.encoder = encoder
        self.container = container
        self.output = output
    }

    public func resolvedContainer(for input: URL) -> OutputContainer {
        container ?? OutputContainer.forURL(output.pathExtension.isEmpty ? input : output)
    }

    /// A default destination beside the input, e.g. `episode.2x.mkv`.
    ///
    /// The extension comes from the container we will actually write, not from the
    /// input's: anything that is not MP4/MOV is muxed as Matroska, so reusing an
    /// `.avi` or `.ts` extension would name an MKV in a way players reject.
    public static func defaultOutputURL(for input: URL, scale: Int) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        let container = OutputContainer.forURL(input)
        return input
            .deletingLastPathComponent()
            .appendingPathComponent("\(base).\(scale)x.\(container.fileExtension)")
    }
}

/// What the job is doing right now.
public enum UpscaleJobPhase: String, Equatable, Sendable {
    case probing
    /// Translating and compiling the preset's shaders for this frame size.
    case compilingShaders
    case processing
    /// ffmpeg is flushing and finalising the container.
    case finalizing
}

/// A progress snapshot, published as frames are written.
public struct UpscaleProgress: Equatable, Sendable {
    public var phase: UpscaleJobPhase
    public var framesProcessed: Int
    /// From the probe; nil when the container gave no usable duration.
    public var totalFrames: Int?
    public var framesPerSecond: Double
    public var elapsed: TimeInterval

    public init(
        phase: UpscaleJobPhase,
        framesProcessed: Int = 0,
        totalFrames: Int? = nil,
        framesPerSecond: Double = 0,
        elapsed: TimeInterval = 0
    ) {
        self.phase = phase
        self.framesProcessed = framesProcessed
        self.totalFrames = totalFrames
        self.framesPerSecond = framesPerSecond
        self.elapsed = elapsed
    }

    public var fractionCompleted: Double? {
        guard let totalFrames, totalFrames > 0 else { return nil }
        return min(1, Double(framesProcessed) / Double(totalFrames))
    }

    public var estimatedTimeRemaining: TimeInterval? {
        guard let totalFrames, totalFrames > framesProcessed, framesPerSecond > 0 else {
            return nil
        }
        return Double(totalFrames - framesProcessed) / framesPerSecond
    }
}

/// Thrown when the job is cancelled; distinguishable from a real failure.
public struct UpscaleCancelled: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "Cancelled." }
}

/// Frame accounting mismatch — the one thing that would silently corrupt A/V sync.
public struct FrameCountMismatch: Error, CustomStringConvertible {
    public let read: Int
    public let written: Int
    public var description: String {
        "Frame count mismatch: decoded \(read) frames but wrote \(written)."
    }
}
