import Foundation

/// A snapshot of ffmpeg's `-progress` output.
public struct FFmpegProgress: Equatable, Sendable {
    public var frame: Int?
    public var fps: Double?
    public var outTimeMicroseconds: Int64?
    public var speed: Double?
    /// True once ffmpeg reports `progress=end`.
    public var isFinished: Bool = false

    public init() {}

    public var outTimeSeconds: Double? {
        outTimeMicroseconds.map { Double($0) / 1_000_000 }
    }
}

/// Splits ffmpeg's stderr into log lines and `-progress` key/value lines.
///
/// `-progress pipe:2` interleaves `key=value` records with ordinary log output on
/// the same stream, so the classifier below is what keeps the two apart. Run ffmpeg
/// with `-nostats` so its own rewriting status line does not also land here.
struct FFmpegStderrParser {
    private var pending = Data()
    private(set) var progress = FFmpegProgress()

    /// Feeds a chunk of stderr; returns the log (non-progress) lines it contained.
    mutating func consume(_ data: Data) -> [String] {
        pending.append(data)
        var logLines: [String] = []

        while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<newlineIndex]
            pending = pending[pending.index(after: newlineIndex)...]
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let (key, value) = FFmpegStderrParser.progressField(in: line) {
                apply(key: key, value: value)
            } else {
                logLines.append(line)
            }
        }
        // Compacting keeps `pending` from growing its backing storage indefinitely.
        pending = Data(pending)
        return logLines
    }

    /// Flushes a trailing line that arrived without a newline (process exit).
    mutating func finish() -> [String] {
        guard !pending.isEmpty else { return [] }
        pending.append(UInt8(ascii: "\n"))
        return consume(Data())
    }

    /// A progress record is exactly `key=value` with a bare key and no spaces.
    ///
    /// ffmpeg log lines that contain `=` always carry a prefix (`[libx264 @ …]`) or
    /// spaces, so requiring the whole line to match keeps them out.
    static func progressField(in line: String) -> (String, String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<equals]
        let value = line[line.index(after: equals)...]
        guard !key.isEmpty, !value.contains(" "),
              key.allSatisfy({ ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "_" })
        else { return nil }
        return (String(key), String(value))
    }

    private mutating func apply(key: String, value: String) {
        switch key {
        case "frame":
            progress.frame = Int(value)
        case "fps":
            progress.fps = Double(value)
        case "out_time_us", "out_time_ms":
            // ffmpeg's `out_time_ms` is a misnomer: it is microseconds, same as out_time_us.
            progress.outTimeMicroseconds = Int64(value)
        case "speed":
            progress.speed = Double(value.hasSuffix("x") ? String(value.dropLast()) : value)
        case "progress":
            progress.isFinished = (value == "end")
        default:
            break
        }
    }
}
