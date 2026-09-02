import Foundation
import simd

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

    // MARK: - Metal conversion

    /// Luma coefficients per matrix, as `(Kr, Kb)`.
    ///
    /// BT.709: ITU-R BT.709-6 Table 3, items 3.2/3.3.
    /// BT.601 625-line (`bt470bg`) and 525-line (`smpte170m`): ITU-R BT.601-7 §2.5.1;
    /// both use the same 0.299/0.114 luma coefficients.
    /// BT.2020 non-constant luminance: ITU-R BT.2020-2 Table 4.
    static func lumaCoefficients(for matrix: String) -> (kr: Double, kb: Double) {
        switch matrix {
        case "bt470bg", "smpte170m", "bt601", "smpte240m":
            return (0.299, 0.114)
        case "bt2020nc", "bt2020_ncl", "bt2020c", "bt2020":
            return (0.2627, 0.0593)
        default:
            // BT.709 is the sane default for anything unrecognised; `from(_:)` has
            // already filled in the size-appropriate matrix when the source said nothing.
            return (0.2126, 0.0722)
        }
    }

    /// True when the samples use the full 0…255 code range rather than 16…235/240.
    var isFullRange: Bool { range == "pc" || range == "full" || range == "jpeg" }

    /// How the sample codes of one bit depth map onto 0…1.
    ///
    /// Limited range maps luma 16…235 and chroma 16…240 (scaled by the depth) onto
    /// 0…1, so the samples are scaled after the offset is removed — BT.709-6 §6.11 and
    /// BT.601-7 §2.5.3 for 8-bit, the same relation shifted left for 10-bit. Full range
    /// needs no scaling, only chroma's half-scale offset.
    private struct SampleRange {
        let lumaScale: Double
        let chromaScale: Double
        let lumaOffset: Double
        let chromaOffset: Double

        init(bitDepth: Int, isFullRange: Bool) {
            let maxCode = Double((1 << bitDepth) - 1)
            let step = Double(1 << (bitDepth - 8))
            lumaScale = isFullRange ? 1 : maxCode / (219 * step)
            chromaScale = isFullRange ? 1 : maxCode / (224 * step)
            lumaOffset = isFullRange ? 0 : 16 * step / maxCode
            chromaOffset = 128 * step / maxCode
        }
    }

    /// What a texture sample has to be multiplied by to become a 0…1 code value.
    ///
    /// 10-bit planes live in `r16Unorm` textures, so Metal hands back `code / 65535`
    /// where the code only spans 0…1023; the difference is folded into the matrix
    /// rather than shifted during upload, which would cost a pass over every frame.
    private static func sampleScale(bitDepth: Int) -> Double {
        let maxCode = Double((1 << bitDepth) - 1)
        return bitDepth <= 8 ? 1 : 65535 / maxCode
    }

    /// The rows and offset of the YUV→RGB and RGB→YUV transforms, in the 0…1 sample
    /// space Metal reads and writes.
    ///
    /// The input and output depths are separate: a 10-bit source can be written out as
    /// 8-bit and the other way round.
    public func metalTransforms(
        inputBitDepth: Int = 8,
        outputBitDepth: Int = 8
    ) -> (toRGB: ColorTransform, toYUV: ColorTransform) {
        let (kr, kb) = ColorProperties.lumaCoefficients(for: matrix)
        let kg = 1 - kr - kb
        // R = Y + 2(1-Kr)Cr, B = Y + 2(1-Kb)Cb, G = (Y - Kr R - Kb B) / Kg.
        let rv = 2 * (1 - kr)
        let bu = 2 * (1 - kb)

        let input = SampleRange(bitDepth: inputBitDepth, isFullRange: isFullRange)
        // The kernel computes `rows * (sample - offset)`, so scaling the samples by `s`
        // is the same as scaling the rows by `s` and dividing the offset by it.
        let readScale = ColorProperties.sampleScale(bitDepth: inputBitDepth)
        let toRGB = ColorTransform(
            rows: [
                SIMD3(Float(input.lumaScale * readScale), 0, Float(input.chromaScale * rv * readScale)),
                SIMD3(
                    Float(input.lumaScale * readScale),
                    Float(-input.chromaScale * bu * kb / kg * readScale),
                    Float(-input.chromaScale * rv * kr / kg * readScale)
                ),
                SIMD3(
                    Float(input.lumaScale * readScale),
                    Float(input.chromaScale * bu * readScale),
                    0
                ),
            ],
            offset: SIMD3(
                Float(input.lumaOffset / readScale),
                Float(input.chromaOffset / readScale),
                Float(input.chromaOffset / readScale)
            )
        )

        // Y = KrR + KgG + KbB, Cb = (B - Y)/2(1-Kb), Cr = (R - Y)/2(1-Kr).
        let output = SampleRange(bitDepth: outputBitDepth, isFullRange: isFullRange)
        // The kernel computes `rows * rgb + offset`, so both are scaled by the write
        // factor, which is the inverse of the read one.
        let writeScale = 1 / ColorProperties.sampleScale(bitDepth: outputBitDepth)
        let toYUV = ColorTransform(
            rows: [
                SIMD3(
                    Float(kr / output.lumaScale * writeScale),
                    Float(kg / output.lumaScale * writeScale),
                    Float(kb / output.lumaScale * writeScale)
                ),
                SIMD3(
                    Float(-kr / bu / output.chromaScale * writeScale),
                    Float(-kg / bu / output.chromaScale * writeScale),
                    Float((1 - kb) / bu / output.chromaScale * writeScale)
                ),
                SIMD3(
                    Float((1 - kr) / rv / output.chromaScale * writeScale),
                    Float(-kg / rv / output.chromaScale * writeScale),
                    Float(-kb / rv / output.chromaScale * writeScale)
                ),
            ],
            offset: SIMD3(
                Float(output.lumaOffset * writeScale),
                Float(output.chromaOffset * writeScale),
                Float(output.chromaOffset * writeScale)
            )
        )
        return (toRGB, toYUV)
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
