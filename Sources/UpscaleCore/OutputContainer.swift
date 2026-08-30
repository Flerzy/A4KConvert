import Foundation

/// The muxer used for the output file, chosen from the output file extension.
///
/// The container decides what can be stream-copied: Matroska takes essentially any
/// audio/subtitle codec plus font attachments, while MP4/MOV only take a narrow set,
/// so text subtitles have to be converted and attachments dropped.
public enum OutputContainer: String, CaseIterable, Sendable {
    case matroska
    case mp4
    case mov

    public static func forExtension(_ fileExtension: String) -> OutputContainer {
        switch fileExtension.lowercased() {
        case "mp4", "m4v": return .mp4
        case "mov": return .mov
        default: return .matroska
        }
    }

    public static func forURL(_ url: URL) -> OutputContainer {
        forExtension(url.pathExtension)
    }

    public var fileExtension: String {
        switch self {
        case .matroska: return "mkv"
        case .mp4: return "mp4"
        case .mov: return "mov"
        }
    }

    /// Matroska carries fonts and other attachments; the ISO-BMFF family does not.
    public var supportsAttachments: Bool { self == .matroska }

    /// Text subtitle codecs, as ffprobe spells them.
    static let textSubtitleCodecs: Set<String> = [
        "subrip", "srt", "ass", "ssa", "mov_text", "text", "webvtt",
    ]

    /// The codec to give `-c:s`, or nil when subtitles cannot be carried at all.
    ///
    /// MP4/MOV can only hold `mov_text`, so SRT/ASS input has to be transcoded and
    /// bitmap subtitles (PGS, VobSub) have no representation there at all. Matroska
    /// takes almost anything, with one exception: `mov_text` is an MP4-only track type,
    /// so a file coming the other way has to be converted to SubRip.
    public func subtitleCodec(forSource codec: String) -> String? {
        let codec = codec.lowercased()
        switch self {
        case .matroska:
            return codec == "mov_text" ? "srt" : "copy"
        case .mp4, .mov:
            return OutputContainer.textSubtitleCodecs.contains(codec) ? "mov_text" : nil
        }
    }

    /// `-f` value for ffmpeg, so the muxer never has to be guessed from the path.
    public var ffmpegFormatName: String {
        switch self {
        case .matroska: return "matroska"
        case .mp4: return "mp4"
        case .mov: return "mov"
        }
    }
}
