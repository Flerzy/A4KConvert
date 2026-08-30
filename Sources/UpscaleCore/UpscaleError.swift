import Foundation

/// Errors surfaced by the core pipeline.
///
/// Every case carries the shortest decisive message from the failing component
/// (ffmpeg stderr, Metal compiler diagnostic, …) rather than a generic string,
/// because the pipeline never falls back silently.
public enum UpscaleError: Error, CustomStringConvertible {
    /// Neither the bundled binary, Homebrew, nor `PATH` provided the tool.
    case toolNotFound(tool: String, searched: [String])
    /// A subprocess exited with a non-zero status.
    case processFailed(tool: String, status: Int32, stderr: String)
    /// A subprocess could not be launched at all.
    case processLaunchFailed(tool: String, underlying: String)
    /// `ffprobe` produced output that did not decode into `MediaInfo`.
    case probeFailed(reason: String)
    /// The input has no decodable video stream.
    case noVideoStream(path: String)
    /// The input uses a feature that v1 deliberately refuses (10-bit, HDR, …).
    case unsupportedInput(reason: String)

    public var description: String {
        switch self {
        case let .toolNotFound(tool, searched):
            return "Could not find \(tool). Searched: \(searched.joined(separator: ", ")). "
                + "Install it with `brew install ffmpeg`."
        case let .processFailed(tool, status, stderr):
            let detail = UpscaleError.decisiveLine(in: stderr)
            return detail.isEmpty
                ? "\(tool) exited with status \(status)."
                : "\(tool) exited with status \(status): \(detail)"
        case let .processLaunchFailed(tool, underlying):
            return "Could not launch \(tool): \(underlying)"
        case let .probeFailed(reason):
            return "ffprobe output could not be read: \(reason)"
        case let .noVideoStream(path):
            return "No video stream found in \(path)."
        case let .unsupportedInput(reason):
            return "Unsupported input: \(reason)"
        }
    }

    /// Picks the single most useful line out of a block of ffmpeg stderr.
    ///
    /// ffmpeg puts its banner, per-stream info and progress on stderr as well, so the
    /// last line is usually the actual failure while everything above it is noise.
    static func decisiveLine(in stderr: String) -> String {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }

        let ignorablePrefixes = ["ffmpeg version", "built with", "configuration:", "lib"]
        let interesting = lines.filter { line in
            !ignorablePrefixes.contains(where: { line.hasPrefix($0) })
        }

        // ffmpeg's closing summary ("bitrate=  0.0kbits/s", "video:0KiB …") is often the
        // last thing on stderr even when the run failed, so prefer the last line that
        // actually reads like a diagnosis.
        let diagnosisMarkers = [
            "error", "invalid", "could not", "cannot", "unable", "failed", "no such",
            "not supported", "unsupported", "denied", "incompatible",
        ]
        if let diagnosis = interesting.last(where: { line in
            let lowered = line.lowercased()
            return diagnosisMarkers.contains { lowered.contains($0) }
        }) {
            return diagnosis
        }
        return interesting.last ?? lines[lines.count - 1]
    }
}
