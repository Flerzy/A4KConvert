import Metal
import MetalPerformanceShaders

/// Runs an Anime4K preset over frames on the GPU.
///
/// Lifetime is: `init` parses the preset's shaders, `configure` plans the chain for a
/// given input and target size and compiles only the passes that survive `//!WHEN`,
/// then `encode` is called once per frame.
public final class Anime4KEngine {
    public let device: MTLDevice
    public let preset: Preset

    private let stages: [MPVShaderStage]
    private let pool: TexturePool
    private var plan: RenderPlan?
    private var pipelines: [MTLComputePipelineState] = []
    private var resolvePipeline: MTLComputePipelineState?
    private var lanczos: MPSImageLanczosScale?
    /// Kept separate from `lanczos` so the skip path exists even when the chain lands
    /// on the target size by itself.
    private var passthroughScaler: MPSImageLanczosScale?

    public init(
        preset: Preset,
        device: MTLDevice,
        catalog: ShaderCatalog = ShaderCatalog()
    ) throws {
        self.preset = preset
        self.device = device
        self.stages = try catalog.stages(for: preset)
        self.pool = TexturePool(device: device)
    }

    /// The chain as planned, available after `configure`.
    public var renderPlan: RenderPlan? { plan }

    /// The size the chain lands on before any final resample.
    public var chainOutputSize: PixelSize? { plan?.finalSize }

    /// Number of intermediate textures allocated so far — zero growth after warmup.
    public var textureAllocationCount: Int { pool.allocationCount }

    // MARK: - Configuration

    public func configure(inputSize: PixelSize, targetSize: PixelSize) throws {
        let plan = try RenderPlan.build(
            stages: stages,
            inputSize: inputSize,
            targetSize: targetSize
        )
        // Everything that can throw runs first: `plan` is only published once the
        // pipelines that match it exist, so `encode` can never index a stale array.
        let pipelines = try compilePipelines(for: plan)
        let resolvePipeline = try makeResolvePipeline()

        self.pipelines = pipelines
        self.resolvePipeline = resolvePipeline
        self.lanczos = plan.producesTargetSize ? nil : MPSImageLanczosScale(device: device)
        self.passthroughScaler = MPSImageLanczosScale(device: device)
        self.plan = plan
        pool.removeAll()
    }

    /// Compiles one library and pipeline per enabled pass.
    ///
    /// The HQ presets carry a few very large CNN shaders, so the stages are compiled
    /// concurrently: this is the dominant cost of starting a job.
    private func compilePipelines(for plan: RenderPlan) throws -> [MTLComputePipelineState] {
        var results = [Result<MTLComputePipelineState, Error>?](
            repeating: nil, count: plan.passes.count
        )
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: plan.passes.count) { index in
            let stage = plan.passes[index].stage
            let result: Result<MTLComputePipelineState, Error>
            do {
                let library = try device.makeLibrary(
                    source: MSLTranslator.metalSource(for: stage), options: nil
                )
                guard let function = library.makeFunction(name: stage.functionName) else {
                    throw EngineError.missingFunction(stage.functionName)
                }
                result = .success(try device.makeComputePipelineState(function: function))
            } catch {
                result = .failure(
                    ShaderError.compilationFailed(
                        stage: "\(stage.sourceFile): \(stage.name)",
                        message: String(describing: error)
                    )
                )
            }
            lock.lock()
            results[index] = result
            lock.unlock()
        }

        return try results.map { result in
            switch result {
            case let .success(pipeline): return pipeline
            case let .failure(error): throw error
            case nil: throw EngineError.notConfigured
            }
        }
    }

    private func makeResolvePipeline() throws -> MTLComputePipelineState {
        let library = try device.makeLibrary(source: ResolveKernel.source, options: nil)
        guard let function = library.makeFunction(name: ResolveKernel.functionName) else {
            throw EngineError.missingFunction(ResolveKernel.functionName)
        }
        return try device.makeComputePipelineState(function: function)
    }

    // MARK: - Rendering

    /// Encodes the whole chain for one frame.
    ///
    /// `input` is the decoded frame (`bgra8Unorm`) and `output` is the destination at
    /// the target size (`bgra8Unorm`). Intermediates come from the pool and go back to
    /// it when the command buffer completes, so two frames can be in flight at once
    /// without sharing textures.
    public func encode(
        commandBuffer: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture
    ) throws {
        guard let plan, let resolvePipeline else { throw EngineError.notConfigured }
        try checkSizes(plan: plan, input: input, output: output)

        let allocator = FrameAllocator(pool: pool)
        var textures = [MTLTexture?](repeating: nil, count: plan.slotSizes.count)
        textures[RenderPlan.inputSlot] = input

        for (index, pass) in plan.passes.enumerated() {
            let destination = try allocator.acquire(width: pass.size.width, height: pass.size.height)
            textures[pass.outputSlot] = destination

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                allocator.returnAllToPool()
                throw EngineError.commandEncoderCreationFailed(stage: pass.stage.name)
            }
            encoder.label = pass.stage.name
            encoder.setComputePipelineState(pipelines[index])
            for (slotIndex, slot) in pass.inputSlots.enumerated() {
                encoder.setTexture(textures[slot], index: slotIndex)
            }
            encoder.setTexture(destination, index: pass.inputSlots.count)
            dispatch(encoder: encoder, pipeline: pipelines[index], size: pass.size)
            encoder.endEncoding()

            // Passes run in order inside one command buffer, so a texture whose last
            // reader has just been encoded can back a later pass in the same frame.
            for slot in textures.indices where plan.lastUse[slot] == index {
                if let texture = textures[slot], slot != RenderPlan.inputSlot {
                    allocator.recycle(texture)
                }
                textures[slot] = nil
            }
        }

        guard var result = textures[plan.finalSlot] else {
            allocator.returnAllToPool()
            throw EngineError.notConfigured
        }

        if !plan.producesTargetSize, let lanczos {
            // The AutoDownscalePre passes normally land the chain exactly on the target,
            // so this only runs for scales where they cannot.
            let resized = try allocator.acquire(
                width: plan.targetSize.width, height: plan.targetSize.height
            )
            lanczos.encode(commandBuffer: commandBuffer, sourceTexture: result, destinationTexture: resized)
            result = resized
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            allocator.returnAllToPool()
            throw EngineError.commandEncoderCreationFailed(stage: "resolve")
        }
        encoder.label = "resolve"
        encoder.setComputePipelineState(resolvePipeline)
        encoder.setTexture(result, index: 0)
        encoder.setTexture(output, index: 1)
        dispatch(encoder: encoder, pipeline: resolvePipeline, size: plan.targetSize)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { _ in
            allocator.returnAllToPool()
        }
    }

    /// Resamples the frame straight to the target size with Lanczos, bypassing every
    /// shader pass. Same texture contract as `encode`; used for skipped segments.
    ///
    /// This is a pure resample of the RGB frame: it deliberately does not touch the
    /// pipe format, so a later move to YUV pipes only has to run it between the two
    /// colour conversions.
    public func encodePassthrough(
        commandBuffer: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture
    ) throws {
        guard let plan, let passthroughScaler else { throw EngineError.notConfigured }
        try checkSizes(plan: plan, input: input, output: output)
        passthroughScaler.encode(
            commandBuffer: commandBuffer, sourceTexture: input, destinationTexture: output
        )
    }

    private func checkSizes(plan: RenderPlan, input: MTLTexture, output: MTLTexture) throws {
        guard input.width == plan.inputSize.width, input.height == plan.inputSize.height else {
            throw EngineError.sizeMismatch(
                expected: plan.inputSize.description,
                got: "\(input.width)x\(input.height)"
            )
        }
        guard output.width == plan.targetSize.width, output.height == plan.targetSize.height else {
            throw EngineError.sizeMismatch(
                expected: plan.targetSize.description,
                got: "\(output.width)x\(output.height)"
            )
        }
    }

    private func dispatch(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        size: PixelSize
    ) {
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        // Every generated kernel guards against overshoot, so rounding up is safe on
        // devices without non-uniform threadgroups.
        let threadgroups = MTLSize(
            width: (size.width + width - 1) / width,
            height: (size.height + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
