import Foundation

/// Decodes a JSON value that ffprobe may spell as either a number or a string.
///
/// ffprobe is inconsistent here by design: `width` is a JSON number while
/// `nb_frames` and `duration` are strings.
@propertyWrapper
struct LenientNumber<Value: LosslessStringConvertible & Codable>: Codable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let value = try? container.decode(Value.self) {
            wrappedValue = value
        } else if let text = try? container.decode(String.self) {
            // ffprobe writes "N/A" for fields it could not determine.
            wrappedValue = text == "N/A" ? nil : Value(text)
        } else {
            wrappedValue = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    func decode<Value>(
        _ type: LenientNumber<Value>.Type,
        forKey key: Key
    ) throws -> LenientNumber<Value> {
        try decodeIfPresent(type, forKey: key) ?? LenientNumber(wrappedValue: nil)
    }
}

/// The subset of `ffprobe -show_streams -show_format` output we consume.
struct FFprobeOutput: Decodable {
    let streams: [FFprobeStream]
    let format: FFprobeFormat?
}

struct FFprobeFormat: Decodable {
    let filename: String?
    let formatName: String?
    @LenientNumber var duration: Double?

    enum CodingKeys: String, CodingKey {
        case filename
        case formatName = "format_name"
        case duration
    }
}

struct FFprobeStream: Decodable {
    let index: Int
    let codecName: String?
    let codecType: String?
    @LenientNumber var width: Int?
    @LenientNumber var height: Int?
    let pixelFormat: String?
    @LenientNumber var bitsPerRawSample: Int?
    let realFrameRate: String?
    let averageFrameRate: String?
    let sampleAspectRatio: String?
    @LenientNumber var frameCount: Int?
    @LenientNumber var duration: Double?
    @LenientNumber var channels: Int?
    let colorRange: String?
    let colorSpace: String?
    let colorPrimaries: String?
    let colorTransfer: String?
    let tags: [String: String]?
    let disposition: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecType = "codec_type"
        case width
        case height
        case pixelFormat = "pix_fmt"
        case bitsPerRawSample = "bits_per_raw_sample"
        case realFrameRate = "r_frame_rate"
        case averageFrameRate = "avg_frame_rate"
        case sampleAspectRatio = "sample_aspect_ratio"
        case frameCount = "nb_frames"
        case duration
        case channels
        case colorRange = "color_range"
        case colorSpace = "color_space"
        case colorPrimaries = "color_primaries"
        case colorTransfer = "color_transfer"
        case tags
        case disposition
    }

    var kind: StreamKind? {
        codecType.flatMap(StreamKind.init(rawValue:))
    }

    /// Tag lookup is case-insensitive: Matroska writes `language`, QuickTime `LANGUAGE`.
    func tag(_ name: String) -> String? {
        guard let tags else { return nil }
        if let exact = tags[name] { return exact }
        return tags.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    var isDefault: Bool { (disposition?["default"] ?? 0) == 1 }
}
