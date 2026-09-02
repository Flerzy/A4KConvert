import Foundation
@testable import UpscaleCore

/// A plain CPU implementation of the 4:2:0 round trip, so the Metal kernels are
/// compared against something written independently of them.
///
/// Deliberately simple: chroma is the average of each 2x2 block going out and is
/// duplicated coming back, which is enough to compare two engine runs with each other.
enum PlanarFixture {
    /// Packs a BGRA fixture into one contiguous planar frame at the format's depth.
    static func encode(
        _ image: ImageFixture,
        color: ColorProperties,
        format: RawFrameFormat
    ) -> Data {
        let transform = color.metalTransforms(outputBitDepth: format.bitDepth).toYUV
        let maxCode = Double((1 << format.bitDepth) - 1)
        let layout = format.planeLayout(width: image.width, height: image.height)
        var bytes = [UInt8](repeating: 0, count: layout.reduce(0) { $0 + $1.byteCount })
        let source = [UInt8](image.bgra)

        // The transform's rows already carry the write scale for the depth, which puts
        // 10-bit codes in the low bits of a 16-bit word; undo it to get plain codes.
        let writeScale = format.bitDepth >= 10 ? 65535.0 / maxCode : 1.0

        func rgb(x: Int, y: Int) -> SIMD3<Float> {
            let index = (y * image.width + x) * 4
            return SIMD3(
                Float(source[index + 2]) / 255,
                Float(source[index + 1]) / 255,
                Float(source[index + 0]) / 255
            )
        }

        func write(_ value: Float, plane: RawFrameFormat.Plane, x: Int, y: Int) {
            let code = Int((Double(value) * writeScale * maxCode).rounded())
            let clamped = min(Int(maxCode), max(0, code))
            let offset = plane.offset + y * plane.bytesPerRow + x * (format.bitDepth >= 10 ? 2 : 1)
            bytes[offset] = UInt8(clamped & 0xFF)
            if format.bitDepth >= 10 {
                bytes[offset + 1] = UInt8((clamped >> 8) & 0xFF)
            }
        }

        for y in 0..<image.height {
            for x in 0..<image.width {
                let yuv = transform.applyAddingOffset(rgb(x: x, y: y))
                write(yuv.x, plane: layout[0], x: x, y: y)
            }
        }
        for y in 0..<layout[1].height {
            for x in 0..<layout[1].width {
                var sum = SIMD2<Float>(0, 0)
                var count: Float = 0
                for dy in 0..<2 where y * 2 + dy < image.height {
                    for dx in 0..<2 where x * 2 + dx < image.width {
                        let yuv = transform.applyAddingOffset(rgb(x: x * 2 + dx, y: y * 2 + dy))
                        sum += SIMD2(yuv.y, yuv.z)
                        count += 1
                    }
                }
                let chroma = sum / max(count, 1)
                write(chroma.x, plane: layout[1], x: x, y: y)
                write(chroma.y, plane: layout[2], x: x, y: y)
            }
        }
        return Data(bytes)
    }

    /// Unpacks a planar frame back into a BGRA fixture, duplicating chroma.
    static func decode(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        color: ColorProperties,
        format: RawFrameFormat
    ) -> ImageFixture {
        let transform = color.metalTransforms(inputBitDepth: format.bitDepth).toRGB
        let maxCode = Double((1 << format.bitDepth) - 1)
        let readScale = format.bitDepth >= 10 ? 65535.0 / maxCode : 1.0
        let layout = format.planeLayout(width: width, height: height)
        var bgra = [UInt8](repeating: 255, count: width * height * 4)

        func read(_ plane: RawFrameFormat.Plane, x: Int, y: Int) -> Float {
            let offset = plane.offset + y * plane.bytesPerRow + x * (format.bitDepth >= 10 ? 2 : 1)
            let code = format.bitDepth >= 10
                ? Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
                : Int(bytes[offset])
            // The transform expects the sample Metal would hand it, so put the code back
            // into the same scale.
            return Float(Double(code) / maxCode / readScale)
        }

        for y in 0..<height {
            for x in 0..<width {
                let yuv = SIMD3(
                    read(layout[0], x: x, y: y),
                    read(layout[1], x: x / 2, y: y / 2),
                    read(layout[2], x: x / 2, y: y / 2)
                )
                let rgb = transform.applySubtractingOffset(yuv)
                let index = (y * width + x) * 4
                bgra[index + 2] = UInt8(min(255, max(0, (rgb.x * 255).rounded())))
                bgra[index + 1] = UInt8(min(255, max(0, (rgb.y * 255).rounded())))
                bgra[index + 0] = UInt8(min(255, max(0, (rgb.z * 255).rounded())))
            }
        }
        return ImageFixture(width: width, height: height, bgra: Data(bgra))
    }
}
