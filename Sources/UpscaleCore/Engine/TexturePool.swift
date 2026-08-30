import Metal

/// Reuses intermediate textures so a long job does no per-frame allocation after warmup.
///
/// Textures are only returned here once the GPU has finished with them; reuse *within*
/// one command buffer is handled by `FrameAllocator`, which is safe because compute
/// passes in a command buffer execute in order.
public final class TexturePool {
    private struct Key: Hashable {
        let width: Int
        let height: Int
    }

    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat
    private let lock = NSLock()
    private var free: [Key: [MTLTexture]] = [:]
    public private(set) var allocationCount = 0

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .rgba16Float) {
        self.device = device
        self.pixelFormat = pixelFormat
    }

    public func acquire(width: Int, height: Int) throws -> MTLTexture {
        let key = Key(width: width, height: height)
        lock.lock()
        if var bucket = free[key], let texture = bucket.popLast() {
            free[key] = bucket
            lock.unlock()
            return texture
        }
        lock.unlock()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        // Intermediates never touch the CPU, so they can live in GPU-private memory.
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw EngineError.textureAllocationFailed(width: width, height: height)
        }
        lock.lock()
        allocationCount += 1
        lock.unlock()
        return texture
    }

    public func release(_ textures: [MTLTexture]) {
        guard !textures.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for texture in textures {
            free[Key(width: texture.width, height: texture.height), default: []].append(texture)
        }
    }

    public func removeAll() {
        lock.lock()
        free.removeAll()
        lock.unlock()
    }
}

/// Hands out textures for a single frame, recycling within the frame first.
///
/// Everything it acquired is returned to the pool in one go when the frame's command
/// buffer completes.
final class FrameAllocator {
    private struct Key: Hashable {
        let width: Int
        let height: Int
    }

    private let pool: TexturePool
    private var recycled: [Key: [MTLTexture]] = [:]
    private(set) var acquired: [MTLTexture] = []

    init(pool: TexturePool) {
        self.pool = pool
    }

    func acquire(width: Int, height: Int) throws -> MTLTexture {
        let key = Key(width: width, height: height)
        if var bucket = recycled[key], let texture = bucket.popLast() {
            recycled[key] = bucket
            return texture
        }
        let texture = try pool.acquire(width: width, height: height)
        acquired.append(texture)
        return texture
    }

    /// Marks a texture as reusable by a later pass in the same command buffer.
    func recycle(_ texture: MTLTexture) {
        recycled[Key(width: texture.width, height: texture.height), default: []].append(texture)
    }

    func returnAllToPool() {
        pool.release(acquired)
        acquired.removeAll()
        recycled.removeAll()
    }
}
