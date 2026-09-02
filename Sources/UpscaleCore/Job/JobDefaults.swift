import Foundation

/// The settings a newly added file starts with.
///
/// The preset is stored by id rather than as a `Preset` so a stored value survives a
/// preset being renamed or dropped between versions; anything unknown falls back to
/// `Preset.default` instead of failing to load the whole set.
public struct JobDefaults: Equatable, Sendable {
    public var presetID: String
    public var scale: Int
    public var encoder: VideoEncoder
    public var quality: Int
    /// Where outputs go. `nil` means "beside the input", the v1 behaviour.
    public var outputFolder: URL?
    /// Whether chapter-detected openings and endings start checked (consumed by the
    /// skip-segment work; harmless until then).
    public var autoSkipChapters: Bool

    public init(
        presetID: String = Preset.default.id,
        scale: Int = 2,
        encoder: VideoEncoder = .hevc,
        quality: Int = EncoderSettings.defaultQuality,
        outputFolder: URL? = nil,
        autoSkipChapters: Bool = true
    ) {
        self.presetID = presetID
        self.scale = scale
        self.encoder = encoder
        self.quality = quality
        self.outputFolder = outputFolder
        self.autoSkipChapters = autoSkipChapters
    }

    public static let standard = JobDefaults()

    public var preset: Preset {
        Preset.preset(id: presetID) ?? .default
    }

    /// The settings one newly added file gets.
    public func settings(for input: URL) -> UpscaleJobSettings {
        UpscaleJobSettings(
            preset: preset,
            scale: scale,
            encoder: EncoderSettings(encoder: encoder, quality: quality),
            output: JobDefaults.outputURL(for: input, scale: scale, in: outputFolder)
        )
    }

    /// The default destination for `input`, in `folder` when one is set.
    ///
    /// The file name always comes from `UpscaleJobSettings.defaultOutputURL`, so the
    /// extension still follows the container we actually write.
    public static func outputURL(for input: URL, scale: Int, in folder: URL?) -> URL {
        let beside = UpscaleJobSettings.defaultOutputURL(for: input, scale: scale)
        guard let folder else { return beside }
        return folder.appendingPathComponent(beside.lastPathComponent)
    }
}
