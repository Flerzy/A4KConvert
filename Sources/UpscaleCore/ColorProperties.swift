import Foundation

/// The colour tags that have to be re-applied on the encode side.
///
/// Raw video over a pipe carries no metadata at all, so whatever the source said about
/// matrix, range, primaries and transfer is lost between the two ffmpeg processes. We
/// read it from the probe and hand it back explicitly — both to the scaler that does
/// the RGB→YUV conversion and to the bitstream tags — or the output comes out with
/// shifted colours.
public struct ColorProperties: Equatable, Sendable {
    public let matrix: String
    public let range: String
    public let primaries: String
    public let transfer: String

    public init(matrix: String, range: String, primaries: String, transfer: String) {
        self.matrix = matrix
        self.range = range
        self.primaries = primaries
        self.transfer = transfer
    }

    /// Fills unspecified fields with the conventional default for the frame size:
    /// BT.709 for HD and above, BT.601 625-line below it.
    public static func from(_ video: VideoStream) -> ColorProperties {
        let isStandardDefinition = video.height <= 576
        let defaultMatrix = isStandardDefinition ? "bt470bg" : "bt709"
        let defaultPrimaries = isStandardDefinition ? "bt470bg" : "bt709"
        let defaultTransfer = isStandardDefinition ? "smpte170m" : "bt709"

        return ColorProperties(
            matrix: normalize(video.colorSpace) ?? defaultMatrix,
            // Video is limited range unless it explicitly says otherwise.
            range: normalize(video.colorRange) ?? "tv",
            primaries: normalize(video.colorPrimaries) ?? defaultPrimaries,
            transfer: normalize(video.colorTransfer) ?? defaultTransfer
        )
    }

    /// ffprobe writes "unknown"/"reserved" for tags the stream did not set.
    static func normalize(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let unspecified: Set<String> = ["unknown", "unspecified", "reserved", "N/A"]
        return unspecified.contains(value.lowercased()) ? nil : value
    }

    /// The `scale` filter names differ from the ffprobe/bitstream names in a few places.
    var scaleMatrixName: String {
        switch matrix {
        case "bt470bg": return "bt470bg"
        case "smpte170m": return "smpte170m"
        case "bt2020nc", "bt2020_ncl": return "bt2020"
        default: return matrix
        }
    }

    /// A `scale` filter that converts the RGB frames coming off the pipe into the
    /// encoder's planar format using the source's own matrix and range.
    public func rgbToYUVFilter(pixelFormat: String) -> String {
        "scale=out_color_matrix=\(scaleMatrixName):out_range=\(range),format=\(pixelFormat)"
    }

    /// A `setparams` filter that stamps all four colour properties onto the frames.
    ///
    /// The obvious spelling — `-colorspace`/`-color_primaries`/`-color_trc` as output
    /// options — does not work: ffmpeg carries the matrix through but drops the
    /// primaries and transfer, leaving the output tagged "unknown" for both regardless
    /// of encoder. Setting them as frame properties in the filter graph is what
    /// actually survives into the container.
    public var setParametersFilter: String {
        "setparams=colorspace=\(matrix):color_primaries=\(primaries)"
            + ":color_trc=\(transfer):range=\(range)"
    }
}
