import Foundation

/// The mpv render-graph hook points the Anime4K presets attach to.
///
/// mpv runs every shader registered at a hook point when the renderer reaches that
/// point, which is why order in the file is not the order of execution: PREKERNEL
/// runs after all MAIN passes, just before the scaling kernel. Clamp_Highlights
/// relies on exactly that — it measures highlights early and clamps at the end.
public enum HookPoint: String, Equatable, Sendable {
    case main = "MAIN"
    case prekernel = "PREKERNEL"

    /// The order the render graph visits hook points in.
    var executionOrder: Int {
        switch self {
        case .main: return 0
        case .prekernel: return 1
        }
    }

    /// Both hook points operate on the image that MAIN names.
    var textureName: String { "MAIN" }
}

/// One `//!DESC …` block of an mpv user shader: its directives plus its GLSL body.
public struct MPVShaderStage: Equatable {
    /// The `//!DESC` text, or a generated name when the shader omitted it.
    public var name: String
    /// The file this stage was parsed from, for error messages.
    public var sourceFile: String
    /// Position within `sourceFile`, so identical DESCs still get unique symbols.
    public var indexInFile: Int
    public var hook: HookPoint
    public var binds: [String]
    /// Where the result goes. `nil` means "back into the hooked texture".
    public var save: String?
    public var components: Int?
    public var width: RPNExpression?
    public var height: RPNExpression?
    public var when: RPNExpression?
    /// The GLSL body, one trimmed line per element.
    public var body: [String]

    public init(
        name: String,
        sourceFile: String,
        indexInFile: Int,
        hook: HookPoint = .main,
        binds: [String] = [],
        save: String? = nil,
        components: Int? = nil,
        width: RPNExpression? = nil,
        height: RPNExpression? = nil,
        when: RPNExpression? = nil,
        body: [String] = []
    ) {
        self.name = name
        self.sourceFile = sourceFile
        self.indexInFile = indexInFile
        self.hook = hook
        self.binds = binds
        self.save = save
        self.components = components
        self.width = width
        self.height = height
        self.when = when
        self.body = body
    }

    /// The texture this stage writes, with `HOOKED` and a missing `//!SAVE`
    /// both resolving to the hook point's own texture.
    public var destinationTexture: String {
        guard let save, save != "HOOKED" else { return hook.textureName }
        return save
    }

    /// The textures the generated kernel takes as arguments, in binding order.
    ///
    /// A stage may use `MAIN_tex` without binding MAIN — Clamp_Highlights does — so
    /// MAIN is appended when the stage hooks it and did not list it.
    public var inputTextures: [String] {
        var names = binds
        if hook == .main, !names.contains("MAIN") {
            names.append("MAIN")
        }
        return names
    }

    /// A unique, valid MSL identifier for the generated kernel.
    public var functionName: String {
        var identifier = ""
        for character in name.unicodeScalars {
            if CharacterSet.alphanumerics.contains(character), character.isASCII {
                identifier.unicodeScalars.append(character)
            } else if identifier.last != "_" {
                identifier.append("_")
            }
        }
        identifier = identifier.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if identifier.isEmpty || identifier.first?.isNumber == true {
            identifier = "stage_" + identifier
        }
        return "\(identifier)_\(indexInFile)"
    }
}
