import Foundation

/// Finds the chapters that usually hold an opening, an ending or a next-episode
/// preview, so they can be offered as skip ranges.
///
/// Deliberately conservative: a title we are unsure about is left alone, because the
/// user can add a range by hand but would not notice a segment quietly skipped.
public enum ChapterSkipDetector {
    public static func skippableRanges(in media: MediaInfo) -> [SkipRange] {
        let ranges = media.chapters.compactMap { chapter -> SkipRange? in
            guard let title = chapter.title, isSkippableTitle(title) else { return nil }
            return SkipRange(start: chapter.start, end: chapter.end, label: title)
        }
        return SkipRanges.normalized(ranges, duration: media.duration)
    }

    static func isSkippableTitle(_ title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return patterns.contains { $0.matches(normalized) }
    }

    /// `OP`, `ED2`, `op 1`; the whole words openings and endings are titled with; and
    /// the two spellings of a preview chapter.
    private static let patterns: [Pattern] = [
        Pattern(#"^(op|ed)\s*\d*$"#),
        Pattern(#"\b(opening|ending|intro|outro|preview)\b"#),
        Pattern(#"^(next episode|next time)( preview)?$"#),
    ]

    private struct Pattern {
        private let regex: NSRegularExpression?

        init(_ pattern: String) {
            regex = try? NSRegularExpression(pattern: pattern)
        }

        func matches(_ text: String) -> Bool {
            guard let regex else { return false }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, range: range) != nil
        }
    }
}
