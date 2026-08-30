import Foundation

/// Loads and parses the vendored `.glsl` files out of the package bundle.
public struct ShaderCatalog {
    /// `Bundle.module` is internal to the package, so it is exposed here for callers
    /// that need the resource bundle explicitly.
    public static let resourceBundle = Bundle.module

    private let bundle: Bundle
    private let subdirectory: String

    public init(bundle: Bundle? = nil, subdirectory: String = "Shaders") {
        self.bundle = bundle ?? ShaderCatalog.resourceBundle
        self.subdirectory = subdirectory
    }

    public func url(for fileName: String) throws -> URL {
        guard let url = bundle.url(
            forResource: fileName,
            withExtension: "glsl",
            subdirectory: subdirectory
        ) else {
            throw ShaderError.missingShaderResource("\(fileName).glsl")
        }
        return url
    }

    public func source(for fileName: String) throws -> String {
        try String(contentsOf: try url(for: fileName), encoding: .utf8)
    }

    public func stages(for fileName: String) throws -> [MPVShaderStage] {
        try MPVShaderParser.parse(try source(for: fileName), fileName: fileName)
    }

    /// The preset's stages, concatenated in file order.
    ///
    /// Hook-point ordering is applied later, when the render graph is built: a stage's
    /// position here is its registration order, which is only the tie-break within a
    /// hook point.
    public func stages(for preset: Preset) throws -> [MPVShaderStage] {
        try preset.shaderFiles.flatMap { try stages(for: $0) }
    }
}
