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

    /// The three planes of one 4:2:0 frame, as single-channel textures.
    ///
    /// Chroma is half size in both directions, so the pipe carries 1.5 bytes per pixel
    /// instead of BGRA's four.
    public struct YUVPlanes {
        public let luma: MTLTexture
        public let chromaBlue: MTLTexture
        public let chromaRed: MTLTexture
        /// The pipe format these planes were made for, which fixes the sample size and
        /// therefore the layout of the contiguous frame they pack into.
        public let format: RawFrameFormat

        public init(
            luma: MTLTexture,
            chromaBlue: MTLTexture,
            chromaRed: MTLTexture,
            format: RawFrameFormat = .yuv420p
        ) {
            self.luma = luma
            self.chromaBlue = chromaBlue
            self.chromaRed = chromaRed
            self.format = format
        }

        public var width: Int { luma.width }
        public var height: Int { luma.height }
        public var bitDepth: Int { format.bitDepth }
    }

    /// 8-bit planes are `r8Unorm`; 10-bit ones are `r16Unorm` with the code in the low
    /// bits, which the colour kernels' matrices already account for.
    public static func planePixelFormat(for format: RawFrameFormat) -> MTLPixelFormat {
        format.bitDepth >= 10 ? .r16Unorm : .r8Unorm
    }

    public static func makePlanes(
        device: MTLDevice,
        width: Int,
        height: Int,
        format: RawFrameFormat = .yuv420p
    ) throws -> YUVPlanes {
        let planePixelFormat = planePixelFormat(for: format)
        let planes = format.planeLayout(width: width, height: height)
        guard planes.count == 3 else {
            throw EngineError.sizeMismatch(expected: "three planes", got: "\(planes.count)")
        }
        func make(_ plane: RawFrameFormat.Plane) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: planePixelFormat,
                width: plane.width,
                height: plane.height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw EngineError.textureAllocationFailed(
                    width: plane.width, height: plane.height
                )
            }
            return texture
        }
        return YUVPlanes(
            luma: try make(planes[0]),
            chromaBlue: try make(planes[1]),
            chromaRed: try make(planes[2]),
            format: format
        )
    }

    /// Splits one contiguous planar frame off the pipe into the three plane textures.
    public static func upload(planar frame: Data, to planes: YUVPlanes) throws {
        let layout = planes.format.planeLayout(width: planes.width, height: planes.height)
        let expected = layout.reduce(0) { $0 + $1.byteCount }
        guard frame.count == expected else {
            throw EngineError.sizeMismatch(
                expected: "\(expected) bytes", got: "\(frame.count) bytes"
            )
        }
        let textures = [planes.luma, planes.chromaBlue, planes.chromaRed]
        frame.withUnsafeBytes { raw in
            for (plane, texture) in zip(layout, textures) {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                    mipmapLevel: 0,
                    withBytes: raw.baseAddress!.advanced(by: plane.offset),
                    bytesPerRow: plane.bytesPerRow
                )
            }
        }
    }

    /// Packs the three plane textures back into one contiguous frame for the pipe.
    public static func readback(
        planes: YUVPlanes,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws {
        let layout = planes.format.planeLayout(width: planes.width, height: planes.height)
        let expected = layout.reduce(0) { $0 + $1.byteCount }
        guard buffer.count == expected else {
            throw EngineError.sizeMismatch(
                expected: "\(expected) bytes", got: "\(buffer.count) bytes"
            )
        }
        let textures = [planes.luma, planes.chromaBlue, planes.chromaRed]
        for (plane, texture) in zip(layout, textures) {
            texture.getBytes(
                buffer.baseAddress!.advanced(by: plane.offset),
                bytesPerRow: plane.bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
    }

    /// Copies a frame into a caller-owned buffer, which the job reuses across frames.
    public static func readback(
        from texture: MTLTexture,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws {
        let bytesPerRow = texture.width * 4
        let expected = bytesPerRow * texture.height
        guard buffer.count == expected else {
            throw EngineError.sizeMismatch(
                expected: "\(expected) bytes", got: "\(buffer.count) bytes"
            )
        }
        texture.getBytes(
            buffer.baseAddress!,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
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
