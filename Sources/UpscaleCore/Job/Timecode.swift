import Foundation

/// Parses and prints the `h:mm:ss.f` timecodes the skip-range fields accept.
public enum Timecode {
    /// Accepts `ss`, `m:ss` and `h:mm:ss`, each with an optional fractional part.
    ///
    /// Returns nil for anything malformed, negative, or with an out-of-range minute or
    /// second field, so a typo can never silently become a skip range of its own.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var seconds = 0.0
        for (position, part) in parts.enumerated() {
            let isLast = position == parts.count - 1
            guard let value = number(part, allowsFraction: isLast) else { return nil }
            // Only the leading field may exceed its natural range: "90" is 90 seconds,
            // but "1:90" is not a valid minute-and-second pair.
            if position > 0, value >= 60 { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static func number(_ text: Substring, allowsFraction: Bool) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count <= 2, allowsFraction || fields.count == 1 else { return nil }
        guard let value = Double(text), value >= 0 else { return nil }
        return value
    }

    /// `m:ss.s`, or `h:mm:ss.s` past an hour.
    public static func format(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let tenths = Int((clamped * 10).rounded())
        let (whole, fraction) = tenths.quotientAndRemainder(dividingBy: 10)
        let (minutes, secs) = whole.quotientAndRemainder(dividingBy: 60)
        let (hours, mins) = minutes.quotientAndRemainder(dividingBy: 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, mins, secs, fraction)
            : String(format: "%d:%02d.%d", mins, secs, fraction)
    }
}
