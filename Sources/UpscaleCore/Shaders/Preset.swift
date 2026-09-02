import Foundation

/// A named, ordered list of Anime4K shader files, as spelled in the project's
/// `GLSL_Instructions.md` mpv key bindings.
///
/// The order is the order mpv applies them in, and it matters: the `AutoDownscalePre`
/// passes sit between the two upscale passes so the second one lands exactly on the
/// target size.
public struct Preset: Identifiable, Equatable, Hashable, Sendable {
    /// How fast the preset is: the "Fast" line-up is meant for lower-end GPUs, the
    /// "HQ" one for higher-end ones. It is the same mode either way.
    public enum Tier: String, Equatable, Hashable, Sendable, CaseIterable {
        case fast
        case highQuality

        public var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .highQuality: return "HQ"
            }
        }
    }

    public let id: String
    public let name: String
    public let tier: Tier
    /// One line on what the mode is for, condensed from Anime4K's own mode table.
    public let summary: String
    /// File names without the `.glsl` extension, in application order.
    public let shaderFiles: [String]

    public init(
        id: String,
        name: String,
        tier: Tier = .fast,
        summary: String = "",
        shaderFiles: [String]
    ) {
        self.id = id
        self.name = name
        self.tier = tier
        self.summary = summary
        self.shaderFiles = shaderFiles
    }

    /// Summaries, one per mode, from `GLSL_Instructions.md`'s "what each mode is
    /// optimized for" table at v4.0.1.
    private enum Summary {
        static let a = "For blurry or smeared sources — most 1080p and old SD anime."
        static let b = "For sources with ringing and aliasing — most 720p and downscaled anime."
        static let c = "For clean sources with only noise — wallpapers, art, 480p downscales."
        static let aa = "Mode A run twice: the highest perceptual quality, and the most ringing."
        static let bb = "Mode B run twice: higher perceptual quality on the same sources."
        static let ca = "Mode C followed by a restore pass; slightly sharper than C alone."
    }

    /// The twelve presets: Anime4K modes A, B, C, A+A, B+B and C+A, each in a Fast and
    /// an HQ variant. The file orderings are copied from the mpv key bindings in
    /// `GLSL_Instructions.md` at the vendored v4.0.1 tag.
    public static let all: [Preset] = [
        // MARK: Fast
        Preset(
            id: "mode-a-fast",
            name: "Mode A (Fast)",
            tier: .fast,
            summary: Summary.a,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_M",
                "Anime4K_Upscale_CNN_x2_M",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Upscale_CNN_x2_S",
            ]
        ),
        Preset(
            id: "mode-b-fast",
            name: "Mode B (Fast)",
            tier: .fast,
            summary: Summary.b,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_Soft_M",
                "Anime4K_Upscale_CNN_x2_M",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Upscale_CNN_x2_S",
            ]
        ),
        Preset(
            id: "mode-c-fast",
            name: "Mode C (Fast)",
            tier: .fast,
            summary: Summary.c,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Upscale_Denoise_CNN_x2_M",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Upscale_CNN_x2_S",
            ]
        ),
        Preset(
            id: "mode-aa-fast",
            name: "Mode A+A (Fast)",
            tier: .fast,
            summary: Summary.aa,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_M",
                "Anime4K_Upscale_CNN_x2_M",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Restore_CNN_S",
                "Anime4K_Upscale_CNN_x2_S",
            ]
        ),
        Preset(
            id: "mode-bb-fast",
            name: "Mode B+B (Fast)",
            tier: .fast,
            summary: Summary.bb,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_Soft_M",
                "Anime4K_Upscale_CNN_x2_M",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Restore_CNN_Soft_S",
                "Anime4K_Upscale_CNN_x2_S",
            ]
        ),
        Preset(
            id: "mode-ca-fast",
            name: "Mode C+A (Fast)",
            tier: .fast,
            summary: Summary.ca,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Upscale_Denoise_CNN_x2_M",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Restore_CNN_S",
                "Anime4K_Upscale_CNN_x2_S",
            ]
        ),

        // MARK: HQ
        Preset(
            id: "mode-a-hq",
            name: "Mode A (HQ)",
            tier: .highQuality,
            summary: Summary.a,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_VL",
                "Anime4K_Upscale_CNN_x2_VL",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Upscale_CNN_x2_M",
            ]
        ),
        Preset(
            id: "mode-b-hq",
            name: "Mode B (HQ)",
            tier: .highQuality,
            summary: Summary.b,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_Soft_VL",
                "Anime4K_Upscale_CNN_x2_VL",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Upscale_CNN_x2_M",
            ]
        ),
        Preset(
            id: "mode-c-hq",
            name: "Mode C (HQ)",
            tier: .highQuality,
            summary: Summary.c,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Upscale_Denoise_CNN_x2_VL",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Upscale_CNN_x2_M",
            ]
        ),
        Preset(
            id: "mode-aa-hq",
            name: "Mode A+A (HQ)",
            tier: .highQuality,
            summary: Summary.aa,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_VL",
                "Anime4K_Upscale_CNN_x2_VL",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Restore_CNN_M",
                "Anime4K_Upscale_CNN_x2_M",
            ]
        ),
        Preset(
            id: "mode-bb-hq",
            name: "Mode B+B (HQ)",
            tier: .highQuality,
            summary: Summary.bb,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_Soft_VL",
                "Anime4K_Upscale_CNN_x2_VL",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Restore_CNN_Soft_M",
                "Anime4K_Upscale_CNN_x2_M",
            ]
        ),
        Preset(
            id: "mode-ca-hq",
            name: "Mode C+A (HQ)",
            tier: .highQuality,
            summary: Summary.ca,
            shaderFiles: [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Upscale_Denoise_CNN_x2_VL",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Restore_CNN_M",
                "Anime4K_Upscale_CNN_x2_M",
            ]
        ),
    ]

    /// A+A (Fast): the mode Anime4K recommends for most sources, at the speed a laptop
    /// GPU can sustain.
    public static let `default` = Preset.preset(id: "mode-aa-fast") ?? Preset.all[0]

    public static func preset(id: String) -> Preset? {
        all.first { $0.id == id }
    }

    public static func presets(tier: Tier) -> [Preset] {
        all.filter { $0.tier == tier }
    }

    /// Every shader file any shipped preset references, deduplicated.
    public static var allShaderFiles: [String] {
        var seen = Set<String>()
        return all.flatMap(\.shaderFiles).filter { seen.insert($0).inserted }
    }
}
