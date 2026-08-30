import Foundation

/// Parses mpv-style user shaders (`//!HOOK`, `//!BIND`, …) into stages.
///
/// Follows mpv's own splitting rule rather than keying off `//!DESC`: directives
/// accumulate, the first ordinary line starts the body, and the next directive after
/// a body starts the next stage.
public enum MPVShaderParser {
    public static func parse(_ source: String, fileName: String) throws -> [MPVShaderStage] {
        var stages: [MPVShaderStage] = []
        var current: MPVShaderStage?
        var inBody = false
        /// Carried across lines for the variable-length-array workaround below.
        var spatialSigma: Double?

        func finish() {
            if let stage = current {
                stages.append(stage)
            }
            current = nil
            inBody = false
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("//!") {
                if inBody { finish() }
                if current == nil {
                    current = MPVShaderStage(
                        name: "\(fileName)#\(stages.count)",
                        sourceFile: fileName,
                        indexInFile: stages.count
                    )
                    spatialSigma = nil
                }
                try apply(directive: line, to: &current!, fileName: fileName)
                continue
            }

            // Licence headers and standalone comments carry nothing we translate.
            if line.hasPrefix("//") { continue }

            guard current != nil else {
                // Code before any directive is not part of a hook; mpv ignores it.
                continue
            }
            inBody = true

            // Metal has no variable-length arrays, so a kernel size derived from
            // SPATIAL_SIGMA has to be folded into a literal at parse time. Ported
            // from Anime4KMetal, which hit the same limitation.
            if line.contains("#define SPATIAL_SIGMA"),
               let sigma = value(after: "SPATIAL_SIGMA", in: line) {
                spatialSigma = sigma
            }
            if line.contains("#define KERNELSIZE int(max(int(SPATIAL_SIGMA), 1) * 2 + 1)"),
               let sigma = spatialSigma {
                let size = max(Int(sigma), 1) * 2 + 1
                current!.body.append("#define KERNELSIZE \(size)")
                continue
            }

            current!.body.append(line)
        }
        finish()

        return stages
    }

    private static func apply(
        directive line: String,
        to stage: inout MPVShaderStage,
        fileName: String
    ) throws {
        let content = String(line.dropFirst(3))
        let fields = content.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard let keyword = fields.first else {
            throw ShaderError.malformedDirective(line, file: fileName)
        }
        let arguments = Array(fields.dropFirst())

        func single() throws -> String {
            guard arguments.count == 1 else {
                throw ShaderError.malformedDirective(line, file: fileName)
            }
            return arguments[0]
        }

        switch keyword {
        case "DESC":
            guard !arguments.isEmpty else {
                throw ShaderError.malformedDirective(line, file: fileName)
            }
            stage.name = arguments.joined(separator: " ")
        case "HOOK":
            let name = try single()
            guard let hook = HookPoint(rawValue: name) else {
                throw ShaderError.unsupportedHook(name, file: fileName)
            }
            stage.hook = hook
        case "BIND":
            stage.binds.append(try single())
        case "SAVE":
            stage.save = try single()
        case "COMPONENTS":
            guard let count = Int(try single()) else {
                throw ShaderError.malformedDirective(line, file: fileName)
            }
            stage.components = count
        case "WIDTH":
            stage.width = RPNExpression(tokens: arguments)
        case "HEIGHT":
            stage.height = RPNExpression(tokens: arguments)
        case "WHEN":
            stage.when = RPNExpression(tokens: arguments)
        default:
            throw ShaderError.unknownDirective(keyword, file: fileName)
        }
    }

    /// Reads the value in `#define SPATIAL_SIGMA <value>`, ignoring any trailing comment.
    private static func value(after name: String, in line: String) -> Double? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let index = fields.firstIndex(of: Substring(name)), index + 1 < fields.count else {
            return nil
        }
        let candidate = fields[index + 1].prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(candidate)
    }
}
