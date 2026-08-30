import Foundation

/// Translates one parsed mpv shader stage into a Metal compute kernel.
///
/// Ported from Anime4KMetal's `MPVShader.metalCode` (Apache-2.0, Copyright 2021 Yi Xie),
/// which in turn mirrors mpv's own user-shader semantics. The structure is kept:
/// GLSL's implicit globals (the bound textures and the current position) become
/// explicit parameters threaded through every user-defined function, and mpv's
/// `NAME_tex` / `NAME_texOff` / `NAME_pos` / `NAME_pt` / `NAME_size` accessors become
/// preprocessor macros over those parameters.
public enum MSLTranslator {
    /// The name of the write-only destination texture in generated kernels.
    ///
    /// Deliberately not `output`, which would collide with a bind of that name.
    static let destinationIdentifier = "upscaleDestination"
    static let positionIdentifier = "mtlPos"
    static let samplerIdentifier = "upscaleSampler"

    public static func metalSource(for stage: MPVShaderStage) -> String {
        let textures = stage.inputTextures
        return header(textures: textures) + body(for: stage, textures: textures)
    }

    // MARK: - Header

    private static func header(textures: [String]) -> String {
        var source = """
        #include <metal_stdlib>
        using namespace metal;

        using vec2 = float2;
        using vec3 = float3;
        using vec4 = float4;
        using ivec2 = int2;
        using ivec3 = int3;
        using ivec4 = int4;
        using uvec2 = uint2;
        using mat2 = float2x2;
        using mat3 = float3x3;
        using mat4 = float4x4;

        // One linear, clamped sampler for every bind. Wherever a stage samples at exact
        // texel centres — same-size reads and `texOff` with integer offsets — linear and
        // nearest agree exactly, and where a stage genuinely resamples (the residual
        // `MAIN_tex` in a depth-to-space pass, or an AutoDownscalePre pass) linear is
        // what mpv does.
        constexpr sampler \(samplerIdentifier)(
            coord::normalized, address::clamp_to_edge, filter::linear
        );


        """

        for texture in textures {
            source += """
            #define \(texture)_pos \(positionIdentifier)
            #define \(texture)_size vec2(\(texture).get_width(), \(texture).get_height())
            #define \(texture)_pt (vec2(1.0, 1.0) / \(texture)_size)
            #define \(texture)_tex(pos) \(texture).sample(\(samplerIdentifier), pos)
            #define \(texture)_texOff(off) \(texture)_tex(\(texture)_pos + \(texture)_pt * vec2(off))


            """
        }
        return source
    }

    // MARK: - Body

    private static func body(for stage: MPVShaderStage, textures: [String]) -> String {
        // Extra parameters every user-defined function gains, and the matching call site.
        var declaration = "float2 \(positionIdentifier), "
        var callSite = "\(positionIdentifier), "
        for texture in textures {
            declaration += "texture2d<float, access::sample> \(texture), "
            callSite += "\(texture), "
        }

        var functionNames: [String] = []
        var insideFunction = false
        var source = ""

        for line in stage.body {
            if !insideFunction, let signature = FunctionSignature(line: line) {
                insideFunction = true
                functionNames.append(signature.name)
                var extra = declaration
                if signature.arguments.isEmpty {
                    extra.removeLast(2)  // drop the trailing ", " before an empty list
                }
                source += "\(signature.returnType)\(signature.name)(\(extra)\(signature.arguments))"
                source += "\(signature.suffix)\n"
                continue
            }
            if insideFunction, line == "}" {
                insideFunction = false
            }
            source += rewriteCalls(in: line, to: functionNames, callSite: callSite) + "\n"
        }

        source += entryPoint(for: stage, textures: textures, callSite: callSite)
        return source
    }

    /// Adds the threaded parameters to every call of a function this stage defined.
    ///
    /// Only names already seen as definitions are rewritten, so GLSL builtins and the
    /// `go_N` macros the shaders define are left alone.
    static func rewriteCalls(in line: String, to functionNames: [String], callSite: String) -> String {
        var result = line
        for name in functionNames {
            result = replaceCalls(of: name, in: result, callSite: callSite)
        }
        return result
    }

    /// Replaces `name(` with `name(<callSite>`, and `name()` with `name(<args>)`.
    ///
    /// Matching on the identifier boundary keeps `get_luma(` from also rewriting a
    /// hypothetical `my_get_luma(`.
    private static func replaceCalls(of name: String, in line: String, callSite: String) -> String {
        var result = ""
        var remainder = Substring(line)
        let needle = name + "("

        while let range = remainder.range(of: needle) {
            let precedingIndex = range.lowerBound
            let isBoundary: Bool
            if precedingIndex == remainder.startIndex {
                isBoundary = true
            } else {
                let previous = remainder[remainder.index(before: precedingIndex)]
                isBoundary = !(previous.isLetter || previous.isNumber || previous == "_")
            }

            result += remainder[remainder.startIndex..<range.upperBound]
            remainder = remainder[range.upperBound...]

            guard isBoundary else { continue }

            if remainder.first == ")" {
                // A no-argument call still needs the threaded parameters.
                result += String(callSite.dropLast(2))
            } else {
                result += callSite
            }
        }
        result += remainder
        return result
    }

    private static func entryPoint(
        for stage: MPVShaderStage,
        textures: [String],
        callSite: String
    ) -> String {
        var parameters: [String] = []
        for (index, texture) in textures.enumerated() {
            parameters.append("texture2d<float, access::sample> \(texture) [[texture(\(index))]]")
        }
        parameters.append(
            "texture2d<float, access::write> \(destinationIdentifier) [[texture(\(textures.count))]]"
        )
        parameters.append("uint2 gid [[thread_position_in_grid]]")

        let hookArguments = String(callSite.dropLast(2))
        return """

        kernel void \(stage.functionName)(
            \(parameters.joined(separator: ",\n    "))
        ) {
            const uint2 size = uint2(
                \(destinationIdentifier).get_width(), \(destinationIdentifier).get_height()
            );
            if (gid.x >= size.x || gid.y >= size.y) { return; }
            // Pixel centres, matching mpv: output pixel n covers [n, n+1) in texel space.
            float2 \(positionIdentifier) = (float2(gid) + float2(0.5)) / float2(size);
            \(destinationIdentifier).write(hook(\(hookArguments)), gid);
        }

        """
    }
}

/// A GLSL function definition whose opening brace is on the same line.
///
/// Every Anime4K stage is written this way (`vec4 hook() {`), which is what lets the
/// translator rewrite definitions with a single pass over the lines.
struct FunctionSignature {
    let returnType: String
    let name: String
    let arguments: String
    let suffix: String

    init?(line: String) {
        guard let braceIndex = line.lastIndex(of: "{"),
              line[line.index(after: braceIndex)...].trimmingCharacters(in: .whitespaces).isEmpty,
              let closeParen = line[line.startIndex..<braceIndex].lastIndex(of: ")"),
              let openParen = line[line.startIndex..<closeParen].firstIndex(of: "(")
        else { return nil }

        let beforeParen = line[line.startIndex..<openParen]
        let words = beforeParen.split(whereSeparator: { $0 == " " || $0 == "\t" })
        // A definition is "<type…> <name>(", so at least a type and a name.
        guard words.count >= 2, let last = words.last,
              last.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              !(last.first?.isNumber ?? true)
        else { return nil }

        // Keywords that make this a statement rather than a definition.
        let controlKeywords: Set<String> = ["if", "for", "while", "switch", "else", "return"]
        guard !controlKeywords.contains(String(last)) else { return nil }

        name = String(last)
        returnType = String(beforeParen[beforeParen.startIndex..<openParen])
            .replacingOccurrences(of: name, with: "", options: .backwards, range: nil)
        arguments = String(line[line.index(after: openParen)..<closeParen])
        // Everything after the closing paren, i.e. the " {" that opens the body.
        suffix = String(line[line.index(after: closeParen)...])
    }
}
