import Foundation

/// A half-open interval of source time, in seconds.
///
/// Frames inside a skip range are still decoded, resampled to the target size and
/// encoded — only the Anime4K chain is bypassed. The output therefore keeps its full
/// length, its audio sync and its subtitles.
public struct SkipRange: Equatable, Hashable, Sendable, Codable {
    public var start: Double
    /// Exclusive; must be greater than `start` to survive normalisation.
    public var end: Double
    /// Where the range came from, e.g. the chapter title.
    public var label: String?

    public init(start: Double, end: Double, label: String? = nil) {
        self.start = start
        self.end = end
        self.label = label
    }

    public var duration: Double { max(0, end - start) }

    /// Ignores the label, so a range the user checked still matches the detected one it
    /// came from after either side has been relabelled.
    public func coversSameTime(as other: SkipRange) -> Bool {
        start == other.start && end == other.end
    }
}

public enum SkipRanges {
    /// Sorts, clamps to `[0, duration]` when the duration is known, drops empty or
    /// inverted ranges, and merges overlapping or touching ones.
    ///
    /// The merged range keeps the first label it was built from: two chapters that
    /// touch are one skip as far as the pipeline is concerned, and "OP" says more in
    /// the row than a joined title would.
    public static func normalized(_ ranges: [SkipRange], duration: Double?) -> [SkipRange] {
        var clamped: [SkipRange] = []
        for range in ranges {
            var start = max(0, range.start)
            var end = range.end
            if let duration, duration > 0 {
                start = min(start, duration)
                end = min(end, duration)
            }
            guard end > start else { continue }
            clamped.append(SkipRange(start: start, end: end, label: range.label))
        }
        clamped.sort { $0.start < $1.start }

        var merged: [SkipRange] = []
        for range in clamped {
            if var last = merged.last, range.start <= last.end {
                last.end = max(last.end, range.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Total length of a normalised list.
    public static func totalDuration(_ ranges: [SkipRange]) -> Double {
        ranges.reduce(0) { $0 + $1.duration }
    }
}

/// Frame-level view of the ranges, built once per job.
///
/// The decode side forces a constant frame rate, so frame `i` is at exactly
/// `i / frameRate` seconds and the mapping needs no timestamps from ffmpeg.
public struct SkipPlan: Equatable, Sendable {
    /// Sorted, disjoint, half-open frame index ranges.
    public let frameRanges: [Range<Int>]

    public init(ranges: [SkipRange], frameRate: Rational) {
        let fps = frameRate.doubleValue
        guard fps > 0 else {
            self.frameRanges = []
            return
        }
        // A frame at time t is skipped when start <= t < end, so both ends round up.
        var built: [Range<Int>] = []
        for range in ranges {
            let first = SkipPlan.firstFrame(atOrAfter: range.start, fps: fps)
            let end = SkipPlan.firstFrame(atOrAfter: range.end, fps: fps)
            guard end > first else { continue }
            if let last = built.last, first <= last.upperBound {
                built[built.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                built.append(first..<end)
            }
        }
        self.frameRanges = built
    }

    /// `ceil(seconds * fps)`, with exact boundaries pulled back onto the integer.
    ///
    /// `3.0 * (24000/1001)` is 71.928…, but a range that starts on a whole second of a
    /// 25 fps source lands on 75.00000000000001 in binary floating point, and a naive
    /// `ceil` would then skip one frame too few.
    private static func firstFrame(atOrAfter seconds: Double, fps: Double) -> Int {
        guard seconds > 0 else { return 0 }
        let exact = seconds * fps
        let rounded = exact.rounded()
        if abs(exact - rounded) < 1e-6 { return max(0, Int(rounded)) }
        return max(0, Int(exact.rounded(.up)))
    }

    public func isSkipped(frame index: Int) -> Bool {
        var low = 0
        var high = frameRanges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = frameRanges[middle]
            if index < range.lowerBound {
                high = middle - 1
            } else if index >= range.upperBound {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    public var skippedFrameCount: Int {
        frameRanges.reduce(0) { $0 + $1.count }
    }

    public var isEmpty: Bool { frameRanges.isEmpty }
}
