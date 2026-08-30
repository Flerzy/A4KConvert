import Foundation

/// Failures from building or running the Metal render chain.
public enum EngineError: Error, CustomStringConvertible {
    case noMetalDevice
    case textureAllocationFailed(width: Int, height: Int)
    case commandEncoderCreationFailed(stage: String)
    case missingFunction(String)
    case notConfigured
    case emptyChain(preset: String)
    case sizeMismatch(expected: String, got: String)

    public var description: String {
        switch self {
        case .noMetalDevice:
            return "No Metal device is available on this machine."
        case let .textureAllocationFailed(width, height):
            return "Could not allocate a \(width)x\(height) texture."
        case let .commandEncoderCreationFailed(stage):
            return "Could not create a compute command encoder for '\(stage)'."
        case let .missingFunction(name):
            return "Compiled library does not contain the kernel '\(name)'."
        case .notConfigured:
            return "The engine was used before configure(inputSize:targetSize:) was called."
        case let .emptyChain(preset):
            return "Preset '\(preset)' produced no enabled passes at this scale."
        case let .sizeMismatch(expected, got):
            return "Texture size mismatch: expected \(expected), got \(got)."
        }
    }
}
