import Metal

/// Creates and moves data through the CPU-visible textures at the ends of the chain.
///
/// Apple Silicon has unified memory, so `storageModeShared` lets ffmpeg's bytes be
/// copied straight into a texture the GPU reads, with no staging blit.
public enum FrameTextures {
    /// The format on both ends of the chain: matches the `bgra` raw frames on the pipes.
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    public static func makeTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw EngineError.textureAllocationFailed(width: width, height: height)
        }
        return texture
    }

    public static func upload(_ frame: Data, to texture: MTLTexture) throws {
        let bytesPerRow = texture.width * 4
        let expected = bytesPerRow * texture.height
        guard frame.count == expected else {
            throw EngineError.sizeMismatch(
                expected: "\(expected) bytes", got: "\(frame.count) bytes"
            )
        }
        frame.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
    }

    public static func readback(from texture: MTLTexture) -> Data {
        let bytesPerRow = texture.width * 4
        var data = Data(count: bytesPerRow * texture.height)
        data.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return data
    }
}
