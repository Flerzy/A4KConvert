import Foundation
import Metal

/// Runs one file end to end: ffmpeg decode → Anime4K on the GPU → ffmpeg encode.
///
/// `run()` blocks until the file is written, so callers put it on a background queue.
/// Cancellation is safe from any thread and tears down both subprocesses.
///
/// `@unchecked Sendable` because the only cross-thread state — the cancellation flag
/// and the two subprocess handles — is guarded by `cancelLock`; everything else is
/// touched solely by the thread that called `run()`.
public final class UpscaleJob: @unchecked Sendable {
    /// Frames allowed in flight on the GPU at once.
    ///
    /// Bounded so memory stays flat: at 1080p→4K each slot costs one 8 MB input plus
    /// one 33 MB output texture. Above two the GPU is already saturated, and the extra
    /// slack only absorbs jitter in the pipes.
    public static let inFlightFrameLimit = 4

    /// Minimum spacing between progress callbacks while frames are being written.
    public static let progressInterval: TimeInterval = 0.1

    public let input: URL
    public let settings: UpscaleJobSettings
    private let tools: FFmpegTools
    private let device: MTLDevice
    private let catalog: ShaderCatalog

    private let cancelLock = NSLock()
    private var isCancelled = false
    private var decode: DecodeProcess?
    private var encode: EncodeProcess?

    public init(
        input: URL,
        settings: UpscaleJobSettings,
        tools: FFmpegTools,
        device: MTLDevice,
        catalog: ShaderCatalog = ShaderCatalog()
    ) {
        self.input = input
        self.settings = settings
        self.tools = tools
        self.device = device
        self.catalog = catalog
    }

    public convenience init(
        input: URL,
        settings: UpscaleJobSettings,
        catalog: ShaderCatalog = ShaderCatalog()
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.noMetalDevice
        }
        self.init(
            input: input,
            settings: settings,
            tools: try FFmpegLocator.locate(),
            device: device,
            catalog: catalog
        )
    }

    /// Asks the job to stop. The `run()` call throws `UpscaleCancelled` shortly after.
    public func cancel() {
        cancelLock.lock()
        isCancelled = true
        let decode = self.decode
        let encode = self.encode
        cancelLock.unlock()

        // Killing the decoder first unblocks a read that is waiting on its pipe.
        decode?.terminate()
        encode?.terminate()
    }

    private var cancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return isCancelled
    }

    private func checkCancelled() throws {
        if cancelled { throw UpscaleCancelled() }
    }

    @discardableResult
    public func run(progress: ((UpscaleProgress) -> Void)? = nil) throws -> MediaInfo {
        let start = Date()
        progress?(UpscaleProgress(phase: .probing))

        // ffmpeg opens the source a second time for the audio/subtitle passthrough, and
        // the encoder truncates its destination on open, so writing over the input
        // would destroy it and then fail. Refuse before anything is opened.
        guard settings.output.resolvingSymlinksInPath().standardizedFileURL
            != input.resolvingSymlinksInPath().standardizedFileURL
        else {
            throw UpscaleError.outputWouldOverwriteInput(path: input.path)
        }

        let media = try Probe(tools: tools).probe(url: input)
        if let reason = media.rejectionReason() {
            throw UpscaleError.unsupportedInput(reason: reason)
        }
        try checkCancelled()

        let container = settings.resolvedContainer(for: input)
        let plan = EncodePlan.make(
            for: media,
            scale: settings.scale,
            settings: settings.encoder,
            container: container,
            format: .bgra
        )
        try EncodeProcess.validate(plan)

        // Compiling the preset happens before any subprocess starts, so a shader error
        // never leaves an ffmpeg running.
        progress?(UpscaleProgress(
            phase: .compilingShaders,
            totalFrames: media.estimatedFrameCount,
            elapsed: Date().timeIntervalSince(start)
        ))
        let engine = try Anime4KEngine(preset: settings.preset, device: device, catalog: catalog)
        let inputSize = PixelSize(width: media.video.width, height: media.video.height)
        let targetSize = PixelSize(width: plan.width, height: plan.height)
        try engine.configure(inputSize: inputSize, targetSize: targetSize)
        try checkCancelled()

        guard let commandQueue = device.makeCommandQueue() else {
            throw EngineError.noMetalDevice
        }

        let decode = DecodeProcess(ffmpeg: tools.ffmpeg, input: input, media: media, format: .bgra)
        let encode = EncodeProcess(
            ffmpeg: tools.ffmpeg,
            source: input,
            media: media,
            output: settings.output,
            plan: plan
        )
        cancelLock.lock()
        self.decode = decode
        self.encode = encode
        cancelLock.unlock()

        // Frame timestamps come from the forced constant rate, not from the container.
        let skipPlan = SkipPlan(
            ranges: SkipRanges.normalized(settings.skipRanges, duration: media.duration),
            frameRate: media.video.realFrameRate
        )

        do {
            try runPipeline(
                media: media,
                decode: decode,
                encode: encode,
                engine: engine,
                skipPlan: skipPlan,
                commandQueue: commandQueue,
                inputSize: inputSize,
                targetSize: targetSize,
                start: start,
                progress: progress
            )
        } catch {
            decode.terminate()
            encode.terminate()
            throw error
        }
        return media
    }

    // MARK: - Pipeline

    /// One frame handed to the GPU and not yet written out.
    private struct InFlightFrame {
        let commandBuffer: MTLCommandBuffer
        let inputTexture: MTLTexture
        let outputTexture: MTLTexture
    }

    private func runPipeline(
        media: MediaInfo,
        decode: DecodeProcess,
        encode: EncodeProcess,
        engine: Anime4KEngine,
        skipPlan: SkipPlan,
        commandQueue: MTLCommandQueue,
        inputSize: PixelSize,
        targetSize: PixelSize,
        start: Date,
        progress: ((UpscaleProgress) -> Void)?
    ) throws {
        try decode.start()
        try encode.start()

        let reader = FrameReader(
            handle: try require(decode.outputHandle, "decoder stdout"),
            frameByteCount: decode.frameByteCount
        )
        let writer = FrameWriter(handle: try require(encode.inputHandle, "encoder stdin"))

        // Preallocated once: the job does no per-frame allocation after this point.
        var freeInputTextures: [MTLTexture] = []
        var freeOutputTextures: [MTLTexture] = []
        for _ in 0..<UpscaleJob.inFlightFrameLimit {
            freeInputTextures.append(
                try FrameTextures.makeTexture(
                    device: device, width: inputSize.width, height: inputSize.height
                )
            )
            freeOutputTextures.append(
                try FrameTextures.makeTexture(
                    device: device, width: targetSize.width, height: targetSize.height
                )
            )
        }

        var inFlight: [InFlightFrame] = []
        var reachedEndOfStream = false
        var closedPipes = false
        var framesPassedThrough = 0
        let totalFrames = media.estimatedFrameCount

        /// Closes our ends of both pipes exactly once.
        func closePipes() {
            guard !closedPipes else { return }
            closedPipes = true
            writer.finish()
            reader.close()
        }

        // A 30-minute source is tens of thousands of frames; a progress bar cannot show
        // more than a few updates a second, so coalesce them.
        var lastReport = Date.distantPast
        func report(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= UpscaleJob.progressInterval else {
                return
            }
            lastReport = now
            let elapsed = now.timeIntervalSince(start)
            progress?(UpscaleProgress(
                phase: .processing,
                framesProcessed: writer.framesWritten,
                totalFrames: totalFrames,
                framesPerSecond: elapsed > 0 ? Double(writer.framesWritten) / elapsed : 0,
                elapsed: elapsed,
                framesPassedThrough: framesPassedThrough
            ))
        }

        do {
        while true {
            try checkCancelled()

            // Fill the pipeline: reading and uploading frame N+1 overlaps the GPU work
            // still running for the frames already committed.
            while !reachedEndOfStream, inFlight.count < UpscaleJob.inFlightFrameLimit {
                // The decode side is constant frame rate, so the count of frames read so
                // far is the index of the one about to be read.
                let frameIndex = reader.framesRead
                guard let frame = try reader.readFrame() else {
                    reachedEndOfStream = true
                    break
                }
                guard let inputTexture = freeInputTextures.popLast(),
                      let outputTexture = freeOutputTextures.popLast()
                else {
                    throw EngineError.textureAllocationFailed(
                        width: inputSize.width, height: inputSize.height
                    )
                }
                try FrameTextures.upload(frame, to: inputTexture)

                guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                    throw EngineError.noMetalDevice
                }
                if skipPlan.isSkipped(frame: frameIndex) {
                    try engine.encodePassthrough(
                        commandBuffer: commandBuffer,
                        input: inputTexture,
                        output: outputTexture
                    )
                    framesPassedThrough += 1
                } else {
                    try engine.encode(
                        commandBuffer: commandBuffer,
                        input: inputTexture,
                        output: outputTexture
                    )
                }
                commandBuffer.commit()
                inFlight.append(
                    InFlightFrame(
                        commandBuffer: commandBuffer,
                        inputTexture: inputTexture,
                        outputTexture: outputTexture
                    )
                )
            }

            guard !inFlight.isEmpty else { break }

            let frame = inFlight.removeFirst()
            frame.commandBuffer.waitUntilCompleted()
            if let error = frame.commandBuffer.error {
                throw error
            }
            try checkCancelled()
            try writer.write(frame: FrameTextures.readback(from: frame.outputTexture))
            freeInputTextures.append(frame.inputTexture)
            freeOutputTextures.append(frame.outputTexture)
            report()
        }
        } catch {
            closePipes()
            // A cancelled job kills ffmpeg, which shows up here as a truncated read or
            // a closed pipe. The cancellation is the real cause, so report that.
            if cancelled { throw UpscaleCancelled() }
            // A broken pipe or a short read usually means one of the ffmpeg processes
            // already failed, and its message says far more than "EPIPE" does.
            try reportSubprocessFailure(decode: decode, encode: encode)
            throw error
        }

        // The throttle may have swallowed the last few frames' updates.
        report(force: true)
        closePipes()

        progress?(UpscaleProgress(
            phase: .finalizing,
            framesProcessed: writer.framesWritten,
            totalFrames: totalFrames,
            elapsed: Date().timeIntervalSince(start),
            framesPassedThrough: framesPassedThrough
        ))

        try decode.waitAndCheck()
        try encode.waitAndCheck()

        guard reader.framesRead == writer.framesWritten else {
            throw FrameCountMismatch(read: reader.framesRead, written: writer.framesWritten)
        }
    }

    /// Rethrows whichever ffmpeg process has already exited non-zero, if any.
    private func reportSubprocessFailure(decode: DecodeProcess, encode: EncodeProcess) throws {
        for process in [encode.process, decode.process] where !process.isRunning {
            try process.waitAndCheck()
        }
    }

    private func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else {
            throw UpscaleError.processLaunchFailed(tool: "ffmpeg", underlying: "no \(what) pipe")
        }
        return value
    }
}
