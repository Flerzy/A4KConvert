import Foundation

/// The texture sizes an mpv shader expression can refer to.
///
/// mpv exposes texture dimensions to `//!WIDTH`, `//!HEIGHT` and `//!WHEN` as
/// `NAME.w` / `NAME.h`, where NAME is a bound texture or one of the well-known
/// names MAIN, NATIVE, OUTPUT, HOOKED.
public struct SizeEnvironment {
    private var sizes: [String: (width: Float, height: Float)] = [:]

    public init() {}

    public subscript(name: String) -> (width: Float, height: Float)? {
        get { sizes[name] }
        set { sizes[name] = newValue }
    }

    public mutating func set(_ name: String, width: Float, height: Float) {
        sizes[name] = (width, height)
    }

    public mutating func set(_ name: String, to other: String) {
        sizes[name] = sizes[other]
    }
}

/// An mpv shader-directive expression in reverse Polish notation.
///
/// mpv writes these postfix, so `OUTPUT.w MAIN.w / 1.200 >` reads as
/// "OUTPUT.w divided by MAIN.w, is that greater than 1.2".
public struct RPNExpression: Equatable {
    public let tokens: [String]

    public init(tokens: [String]) {
        self.tokens = tokens
    }

    public init(_ text: String) {
        self.init(tokens: text.split(separator: " ").map(String.init).filter { !$0.isEmpty })
    }

    public var isEmpty: Bool { tokens.isEmpty }

    /// Comparisons yield 1 or 0, so a `//!WHEN` result is just "non-zero means run".
    public func evaluate(in environment: SizeEnvironment) throws -> Float {
        var stack: [Float] = []

        func pop() throws -> Float {
            guard let value = stack.popLast() else {
                throw ShaderError.badExpression(tokens.joined(separator: " "), "stack underflow")
            }
            return value
        }

        for token in tokens {
            if let size = try sizeReference(token, in: environment) {
                stack.append(size)
                continue
            }
            switch token {
            case "+": let r = try pop(), l = try pop(); stack.append(l + r)
            case "-": let r = try pop(), l = try pop(); stack.append(l - r)
            case "*": let r = try pop(), l = try pop(); stack.append(l * r)
            case "/": let r = try pop(), l = try pop(); stack.append(l / r)
            case "<": let r = try pop(), l = try pop(); stack.append(l < r ? 1 : 0)
            case ">": let r = try pop(), l = try pop(); stack.append(l > r ? 1 : 0)
            case "!": let v = try pop(); stack.append(v == 0 ? 1 : 0)
            default:
                guard let literal = Float(token) else {
                    throw ShaderError.badExpression(
                        tokens.joined(separator: " "), "unknown token '\(token)'"
                    )
                }
                stack.append(literal)
            }
        }

        guard stack.count == 1 else {
            throw ShaderError.badExpression(
                tokens.joined(separator: " "), "expression left \(stack.count) values on the stack"
            )
        }
        return stack[0]
    }

    /// Resolves `NAME.w` / `NAME.h`, or returns nil when the token is not a size.
    private func sizeReference(_ token: String, in environment: SizeEnvironment) throws -> Float? {
        guard let dot = token.lastIndex(of: "."), dot != token.startIndex else { return nil }
        let axis = token[token.index(after: dot)...]
        guard axis == "w" || axis == "h" else { return nil }
        let name = String(token[token.startIndex..<dot])
        guard let size = environment[name] else {
            throw ShaderError.badExpression(
                tokens.joined(separator: " "), "unknown texture '\(name)'"
            )
        }
        return axis == "w" ? size.width : size.height
    }
}
