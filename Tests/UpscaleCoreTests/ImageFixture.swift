import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// An 8-bit BGRA image, the layout the pipeline moves frames in.
struct ImageFixture {
    let width: Int
    let height: Int
    /// Tightly packed BGRA, `width * height * 4` bytes.
    let bgra: Data

    static func load(named name: String) throws -> ImageFixture {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "png", subdirectory: "Fixtures"
        ) else {
            throw XCTSkip("Fixture \(name).png is missing from the test bundle.")
        }
        return try load(contentsOf: url)
    }

    static func load(contentsOf url: URL) throws -> ImageFixture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageFixtureError.decodeFailed(url.lastPathComponent)
        }

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        // Little-endian 32-bit with premultiplied-first alpha gives B,G,R,A in memory,
        // matching MTLPixelFormat.bgra8Unorm and ffmpeg's `bgra`.
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageFixtureError.decodeFailed(url.lastPathComponent)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ImageFixture(width: width, height: height, bgra: Data(bytes))
    }

    /// Mean absolute per-channel difference over R, G and B, in 0...255 units.
    ///
    /// Alpha is ignored: the chain writes an opaque alpha and the reference PNG has none.
    func meanAbsoluteDifference(to other: ImageFixture) throws -> Double {
        guard width == other.width, height == other.height else {
            throw ImageFixtureError.sizeMismatch(
                "\(width)x\(height)", "\(other.width)x\(other.height)"
            )
        }
        var total = 0.0
        var count = 0
        bgra.withUnsafeBytes { lhs in
            other.bgra.withUnsafeBytes { rhs in
                for pixel in 0..<(width * height) {
                    for channel in 0..<3 {
                        let index = pixel * 4 + channel
                        total += abs(Double(lhs[index]) - Double(rhs[index]))
                        count += 1
                    }
                }
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    /// Writes a PNG, used to leave an artefact behind when a golden test fails.
    func writePNG(to url: URL) throws {
        var bytes = [UInt8](bgra)
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ), let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ImageFixtureError.encodeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageFixtureError.encodeFailed(url.lastPathComponent)
        }
    }
}

enum ImageFixtureError: Error, CustomStringConvertible {
    case decodeFailed(String)
    case encodeFailed(String)
    case sizeMismatch(String, String)

    var description: String {
        switch self {
        case let .decodeFailed(name): return "Could not decode \(name)."
        case let .encodeFailed(name): return "Could not encode \(name)."
        case let .sizeMismatch(lhs, rhs): return "Image sizes differ: \(lhs) vs \(rhs)."
        }
    }
}
