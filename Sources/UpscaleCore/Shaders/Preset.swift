import Foundation

/// A named, ordered list of Anime4K shader files, as spelled in the project's
/// `GLSL_Instructions.md` mpv key bindings.
///
/// The order is the order mpv applies them in, and it matters: the `AutoDownscalePre`
/// passes sit between the two upscale passes so the second one lands exactly on the
/// target size.
public struct Preset: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// File names without the `.glsl` extension, in application order.
    public let shaderFiles: [String]

    public init(id: String, name: String, shaderFiles: [String]) {
        self.id = id
        self.name = name
        self.shaderFiles = shaderFiles
    }

    /// The four presets v1 ships: Anime4K modes A and A+A, each in a Fast and an HQ
    /// variant. "Fast" is the lower-end-GPU line-up, "HQ" the higher-end one.
    public static let all: [Preset] = [
        Preset(
            id: "mode-a-fast",
            name: "Mode A (Fast)",
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
            id: "mode-a-hq",
            name: "Mode A (HQ)",
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
            id: "mode-aa-fast",
            name: "Mode A+A (Fast)",
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
            id: "mode-aa-hq",
            name: "Mode A+A (HQ)",
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
    ]

    public static let `default` = Preset.all[2]

    public static func preset(id: String) -> Preset? {
        all.first { $0.id == id }
    }

    /// Every shader file any shipped preset references, deduplicated.
    public static var allShaderFiles: [String] {
        var seen = Set<String>()
        return all.flatMap(\.shaderFiles).filter { seen.insert($0).inserted }
    }
}
