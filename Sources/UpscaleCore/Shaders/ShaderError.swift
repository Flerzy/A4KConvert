import Foundation

/// Failures from parsing, translating or compiling an mpv user shader.
public enum ShaderError: Error, CustomStringConvertible {
    case unknownDirective(String, file: String)
    case malformedDirective(String, file: String)
    case badExpression(String, String)
    case missingShaderResource(String)
    case compilationFailed(stage: String, message: String)
    case unknownTexture(String, stage: String)
    case unsupportedHook(String, file: String)

    public var description: String {
        switch self {
        case let .unknownDirective(directive, file):
            return "Unknown shader directive '\(directive)' in \(file)."
        case let .malformedDirective(directive, file):
            return "Malformed shader directive '\(directive)' in \(file)."
        case let .badExpression(expression, reason):
            return "Could not evaluate '\(expression)': \(reason)."
        case let .missingShaderResource(name):
            return "Shader resource '\(name)' is missing from the bundle."
        case let .compilationFailed(stage, message):
            return "Metal could not compile '\(stage)': \(message)"
        case let .unknownTexture(name, stage):
            return "Stage '\(stage)' binds texture '\(name)', which nothing produced."
        case let .unsupportedHook(hook, file):
            return "Hook point '\(hook)' in \(file) is not supported."
        }
    }
}
