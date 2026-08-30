import Foundation

/// An exact rational number, used for frame rates and sample aspect ratios.
///
/// Frame rates stay rational end-to-end: 24000/1001 rounded to 23.976 and handed
/// back to ffmpeg is the classic source of slow A/V drift over a long file.
public struct Rational: Equatable, Hashable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(_ numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public static let zero = Rational(0, 1)
    public static let one = Rational(1, 1)

    public var isZero: Bool { numerator == 0 || denominator == 0 }

    public var doubleValue: Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }

    /// The `num/den` spelling ffmpeg accepts for `-r`, `-framerate` and `-aspect`.
    public var ffmpegArgument: String { "\(numerator)/\(denominator)" }

    /// Parses ffprobe's `"24000/1001"` form, and tolerates a bare `"25"`.
    ///
    /// ffprobe spells frame rates with `/` but aspect ratios with `:`, so both
    /// separators are accepted.
    public static func parse(_ text: String) -> Rational? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(
            whereSeparator: { $0 == "/" || $0 == ":" }
        )
        guard (1...2).contains(parts.count) else { return nil }
        if parts.count == 1 {
            guard let whole = Int(parts[0]) else { return nil }
            return Rational(whole, 1)
        }
        guard let numerator = Int(parts[0]), let denominator = Int(parts[1]) else { return nil }
        return Rational(numerator, denominator)
    }

    /// Reduces by the greatest common divisor, keeping the sign on the numerator.
    public var reduced: Rational {
        guard numerator != 0, denominator != 0 else { return self }
        var a = abs(numerator)
        var b = abs(denominator)
        while b != 0 { (a, b) = (b, a % b) }
        let sign = (numerator < 0) != (denominator < 0) ? -1 : 1
        return Rational(sign * abs(numerator) / a, abs(denominator) / a)
    }
}

extension Rational: CustomStringConvertible {
    public var description: String { ffmpegArgument }
}
