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
    /// The final stream-copy join, when the job is cutting ranges out.
    private var joinProcess: FFmpegProcess?

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
        let join = self.joinProcess
        cancelLock.unlock()

        // Killing the decoder first unblocks a read that is waiting on its pipe.
        decode?.terminate()
        encode?.terminate()
        join?.terminate()
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
        // Both pipes follow the depths involved: the decode side the source's, the
        // encode side the one being written.
        let decodeFormat = RawFrameFormat.planar(bitDepth: media.video.bitDepth)
        let encodeFormat = RawFrameFormat.planar(bitDepth: settings.encoder.outputBitDepth)
        let plan = EncodePlan.make(
            for: media,
            scale: settings.scale,
            settings: settings.encoder,
            container: container,
            format: encodeFormat
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
        try engine.configure(
            inputSize: inputSize,
            targetSize: targetSize,
            color: plan.color,
            inputBitDepth: decodeFormat.bitDepth,
            outputBitDepth: encodeFormat.bitDepth
        )
        try checkCancelled()

        guard let commandQueue = device.makeCommandQueue() else {
            throw EngineError.noMetalDevice
        }

        let normalizedSkips = SkipRanges.normalized(
            settings.skipRanges, duration: media.duration
        )

        switch settings.skipMode {
        case .resample:
            // Frame timestamps come from the forced constant rate, not the container.
            let skipPlan = SkipPlan(
                ranges: normalizedSkips, frameRate: media.video.realFrameRate
            )
            try runSegment(
                media: media,
                plan: plan,
                engine: engine,
                decodeFormat: decodeFormat,
                encodeFormat: encodeFormat,
                skipPlan: skipPlan,
                trim: nil,
                output: settings.output,
                commandQueue: commandQueue,
                inputSize: inputSize,
                targetSize: targetSize,
                start: start,
                framesBefore: 0,
                totalFrames: media.estimatedFrameCount,
                progress: progress
            )

        case .cut:
            try runCut(
                media: media,
                plan: plan,
                engine: engine,
                decodeFormat: decodeFormat,
                encodeFormat: encodeFormat,
                skipped: normalizedSkips,
                commandQueue: commandQueue,
                inputSize: inputSize,
                targetSize: targetSize,
                start: start,
                progress: progress
            )
        }
        return media
    }

    // MARK: - Cutting

    /// Runs one pass per kept range, then joins the parts.
    ///
    /// The skipped parts are never decoded, which is the whole point: on a file where
    /// only the first ninety seconds are wanted, the other twenty-two minutes cost
    /// nothing at all. Each part is encoded with identical settings, so joining them is
    /// a stream copy.
    private func runCut(
        media: MediaInfo,
        plan: EncodePlan,
        engine: Anime4KEngine,
        decodeFormat: RawFrameFormat,
        encodeFormat: RawFrameFormat,
        skipped: [SkipRange],
        commandQueue: MTLCommandQueue,
        inputSize: PixelSize,
        targetSize: PixelSize,
        start: Date,
        progress: ((UpscaleProgress) -> Void)?
    ) throws {
        let kept = SkipRanges.kept(from: skipped, duration: media.duration)
        guard !kept.isEmpty else {
            throw UpscaleError.unsupportedInput(
                reason: "Every part of the file is skipped, so there is nothing to write."
            )
        }
        // Nothing to cut: one pass over the whole file, no temporary files.
        guard skipped.contains(where: { $0.duration > 0 }) else {
            try runSegment(
                media: media, plan: plan, engine: engine,
                decodeFormat: decodeFormat, encodeFormat: encodeFormat,
                skipPlan: SkipPlan(ranges: [], frameRate: media.video.realFrameRate),
                trim: nil, output: settings.output, commandQueue: commandQueue,
                inputSize: inputSize, targetSize: targetSize, start: start,
                framesBefore: 0, totalFrames: media.estimatedFrameCount, progress: progress
            )
            return
        }

        let rate = media.video.realFrameRate.doubleValue
        let totalFrames = Int(
            (kept.reduce(0.0) { $0 + min($1.duration, media.duration ?? $1.duration) } * rate)
                .rounded()
        )
        let emptySkipPlan = SkipPlan(ranges: [], frameRate: media.video.realFrameRate)

        if kept.count == 1 {
            try runSegment(
                media: media, plan: plan, engine: engine,
                decodeFormat: decodeFormat, encodeFormat: encodeFormat,
                skipPlan: emptySkipPlan, trim: kept[0], output: settings.output,
                commandQueue: commandQueue, inputSize: inputSize, targetSize: targetSize,
                start: start, framesBefore: 0, totalFrames: totalFrames, progress: progress
            )
            return
        }

        // Parts live beside the output, so joining them never crosses a volume.
        let workDirectory = settings.output
            .deletingLastPathComponent()
            .appendingPathComponent(".upscale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        var parts: [URL] = []
        var framesBefore = 0
        for (index, range) in kept.enumerated() {
            try checkCancelled()
            let part = workDirectory.appendingPathComponent(
                "part-\(index).\(plan.container.fileExtension)"
            )
            try runSegment(
                media: media, plan: plan, engine: engine,
                decodeFormat: decodeFormat, encodeFormat: encodeFormat,
                skipPlan: emptySkipPlan, trim: range, output: part,
                commandQueue: commandQueue, inputSize: inputSize, targetSize: targetSize,
                start: start, framesBefore: framesBefore, totalFrames: totalFrames,
                progress: progress
            )
            framesBefore += Int((range.duration * rate).rounded())
            parts.append(part)
        }

        progress?(UpscaleProgress(
            phase: .finalizing,
            framesProcessed: framesBefore,
            totalFrames: totalFrames,
            elapsed: Date().timeIntervalSince(start)
        ))
        try join(parts: parts, in: workDirectory, to: settings.output, plan: plan)
    }

    /// Joins the encoded parts with the concat demuxer. Every part came out of the same
    /// encoder at the same size, so this is a copy, not a re-encode.
    private func join(parts: [URL], in directory: URL, to output: URL, plan: EncodePlan) throws {
        let list = directory.appendingPathComponent("parts.txt")
        let text = parts
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try (text + "\n").write(to: list, atomically: true, encoding: .utf8)

        let join = FFmpegProcess(
            label: "ffmpeg (join)",
            executable: tools.ffmpeg,
            arguments: [
                "-nostdin", "-v", "error", "-y",
                "-f", "concat", "-safe", "0", "-i", list.path,
                "-map", "0", "-c", "copy",
                "-f", plan.container.ffmpegFormatName,
                output.path,
            ]
        )
        cancelLock.lock()
        self.joinProcess = join
        cancelLock.unlock()
        defer {
            cancelLock.lock()
            self.joinProcess = nil
            cancelLock.unlock()
        }

        try join.start()
        try join.waitAndCheck()
        try checkCancelled()
    }

    /// One decode/GPU/encode pass over one range of the source, or over all of it.
    private func runSegment(
        media: MediaInfo,
        plan: EncodePlan,
        engine: Anime4KEngine,
        decodeFormat: RawFrameFormat,
        encodeFormat: RawFrameFormat,
        skipPlan: SkipPlan,
        trim: SkipRange?,
        output: URL,
        commandQueue: MTLCommandQueue,
        inputSize: PixelSize,
        targetSize: PixelSize,
        start: Date,
        framesBefore: Int,
        totalFrames: Int?,
        progress: ((UpscaleProgress) -> Void)?
    ) throws {
        let decode = DecodeProcess(
            ffmpeg: tools.ffmpeg, input: input, media: media, format: decodeFormat, trim: trim
        )
        let encode = EncodeProcess(
            ffmpeg: tools.ffmpeg,
            source: input,
            media: media,
            output: output,
            plan: plan,
            trim: trim
        )
        cancelLock.lock()
        self.decode = decode
        self.encode = encode
        cancelLock.unlock()

        do {
            try runPipeline(
                media: media,
                decode: decode,
                encode: encode,
                engine: engine,
                decodeFormat: decodeFormat,
                encodeFormat: encodeFormat,
                skipPlan: skipPlan,
                commandQueue: commandQueue,
                inputSize: inputSize,
                targetSize: targetSize,
                start: start,
                framesBefore: framesBefore,
                totalFrames: totalFrames,
                progress: progress
            )
        } catch {
            decode.terminate()
            encode.terminate()
            throw error
        }
    }

    // MARK: - Pipeline

    /// The textures and the readback buffer one in-flight frame owns.
    ///
    /// A slot moves producer → consumer → free list and back, so only one thread ever
    /// touches it; that is what lets the readback buffer be reused with no locking.
    private final class FrameSlot {
        let input: FrameTextures.YUVPlanes
        let output: FrameTextures.YUVPlanes
        var buffer: [UInt8]

        init(input: FrameTextures.YUVPlanes, output: FrameTextures.YUVPlanes, byteCount: Int) {
            self.input = input
            self.output = output
            self.buffer = [UInt8](repeating: 0, count: byteCount)
        }
    }

    /// One frame handed to the GPU and not yet written out.
    private struct InFlightFrame {
        let commandBuffer: MTLCommandBuffer
        let slot: FrameSlot
        let wasPassedThrough: Bool
    }

    /// Hands frames from the producer thread to the consumer thread, and free slots
    /// back the other way.
    ///
    /// The free list is what bounds the pipeline: a producer can only start a frame
    /// once the consumer has released a slot, so memory stays flat at
    /// `inFlightFrameLimit` slots. Both directions share one condition, so a failure on
    /// either side wakes whatever the other side is blocked on.
    private final class FrameChannel {
        private let condition = NSCondition()
        private var ready: [InFlightFrame] = []
        private var free: [FrameSlot]
        private var producerFinished = false
        private var failure: Error?

        init(slots: [FrameSlot]) {
            self.free = slots
        }

        /// Blocks until a slot is free. Throws once either side has failed.
        func takeSlot() throws -> FrameSlot {
            condition.lock()
            defer { condition.unlock() }
            while free.isEmpty, failure == nil {
                condition.wait()
            }
            if let failure { throw failure }
            return free.removeLast()
        }

        func submit(_ frame: InFlightFrame) {
            condition.lock()
            ready.append(frame)
            condition.signal()
            condition.unlock()
        }

        /// Blocks until a frame is ready; nil once the producer has finished cleanly.
        func nextFrame() throws -> InFlightFrame? {
            condition.lock()
            defer { condition.unlock() }
            while ready.isEmpty, !producerFinished, failure == nil {
                condition.wait()
            }
            if let failure { throw failure }
            return ready.isEmpty ? nil : ready.removeFirst()
        }

        func release(_ slot: FrameSlot) {
            condition.lock()
            free.append(slot)
            condition.signal()
            condition.unlock()
        }

        func finish() {
            condition.lock()
            producerFinished = true
            condition.broadcast()
            condition.unlock()
        }

        /// Records the first failure and wakes both sides.
        func fail(_ error: Error) {
            condition.lock()
            if failure == nil { failure = error }
            condition.broadcast()
            condition.unlock()
        }

        var hasFailed: Bool {
            condition.lock()
            defer { condition.unlock() }
            return failure != nil
        }
    }

    private func runPipeline(
        media: MediaInfo,
        decode: DecodeProcess,
        encode: EncodeProcess,
        engine: Anime4KEngine,
        decodeFormat: RawFrameFormat,
        encodeFormat: RawFrameFormat,
        skipPlan: SkipPlan,
        commandQueue: MTLCommandQueue,
        inputSize: PixelSize,
        targetSize: PixelSize,
        start: Date,
        framesBefore: Int,
        totalFrames: Int?,
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
        let outputByteCount = encodeFormat.frameByteCount(
            width: targetSize.width, height: targetSize.height
        )
        var slots: [FrameSlot] = []
        for _ in 0..<UpscaleJob.inFlightFrameLimit {
            slots.append(
                FrameSlot(
                    input: try FrameTextures.makePlanes(
                        device: device, width: inputSize.width, height: inputSize.height,
                        format: decodeFormat
                    ),
                    output: try FrameTextures.makePlanes(
                        device: device, width: targetSize.width, height: targetSize.height,
                        format: encodeFormat
                    ),
                    byteCount: outputByteCount
                )
            )
        }

        var closedPipes = false
        let channel = FrameChannel(slots: slots)

        /// Closes our ends of both pipes exactly once.
        func closePipes() {
            guard !closedPipes else { return }
            closedPipes = true
            writer.finish()
            reader.close()
        }

        // A 30-minute source is tens of thousands of frames; a progress bar cannot show
        // more than a few updates a second, so coalesce them. Called on the consumer
        // thread, which is the only side that knows how many frames are out.
        var lastReport = Date.distantPast
        var framesPassedThrough = 0
        func report(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= UpscaleJob.progressInterval else {
                return
            }
            lastReport = now
            let elapsed = now.timeIntervalSince(start)
            // A cut job runs one pass per kept range, so the counts carry across passes.
            let written = framesBefore + writer.framesWritten
            progress?(UpscaleProgress(
                phase: .processing,
                framesProcessed: written,
                totalFrames: totalFrames,
                framesPerSecond: elapsed > 0 ? Double(written) / elapsed : 0,
                elapsed: elapsed,
                framesPassedThrough: framesPassedThrough
            ))
        }

        // The consumer drains the GPU and feeds the encoder while the producer is
        // already reading and committing the next frames; without the split, the GPU
        // sat idle for the length of every pipe write.
        let consumerFinished = DispatchSemaphore(value: 0)
        let consumer = Thread {
            defer { consumerFinished.signal() }
            do {
                while let frame = try channel.nextFrame() {
                    frame.commandBuffer.waitUntilCompleted()
                    if let error = frame.commandBuffer.error { throw error }
                    try self.checkCancelled()
                    try frame.slot.buffer.withUnsafeMutableBytes { buffer in
                        try FrameTextures.readback(planes: frame.slot.output, into: buffer)
                        try writer.write(bytes: UnsafeRawBufferPointer(buffer))
                    }
                    if frame.wasPassedThrough { framesPassedThrough += 1 }
                    channel.release(frame.slot)
                    report()
                }
            } catch {
                channel.fail(error)
            }
        }
        consumer.name = "upscale.frame-writer"
        consumer.stackSize = 512 * 1024
        consumer.start()

        do {
            while true {
                try checkCancelled()
                // The decode side is constant frame rate, so the count of frames read so
                // far is the index of the one about to be read.
                let frameIndex = reader.framesRead
                // Blocks until the consumer has released a slot, which is what bounds
                // the pipeline.
                let slot = try channel.takeSlot()
                guard let frame = try reader.readFrame() else {
                    channel.release(slot)
                    break
                }
                try FrameTextures.upload(planar: frame, to: slot.input)

                guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                    throw EngineError.noMetalDevice
                }
                let isSkipped = skipPlan.isSkipped(frame: frameIndex)
                if isSkipped {
                    try engine.encodePassthrough(
                        commandBuffer: commandBuffer,
                        input: slot.input,
                        output: slot.output
                    )
                } else {
                    try engine.encode(
                        commandBuffer: commandBuffer,
                        input: slot.input,
                        output: slot.output
                    )
                }
                commandBuffer.commit()
                channel.submit(
                    InFlightFrame(
                        commandBuffer: commandBuffer, slot: slot, wasPassedThrough: isSkipped
                    )
                )
            }
        } catch {
            channel.fail(error)
            consumerFinished.wait()
            closePipes()
            // A cancelled job kills ffmpeg, which shows up here as a truncated read or
            // a closed pipe. The cancellation is the real cause, so report that.
            if cancelled { throw UpscaleCancelled() }
            // A broken pipe or a short read usually means one of the ffmpeg processes
            // already failed, and its message says far more than "EPIPE" does.
            try reportSubprocessFailure(decode: decode, encode: encode)
            throw error
        }

        channel.finish()
        consumerFinished.wait()

        // The consumer stops on its own error too, and that error has to surface as the
        // job's failure rather than as a frame-count mismatch.
        if channel.hasFailed {
            do {
                _ = try channel.takeSlot()
            } catch {
                closePipes()
                if cancelled { throw UpscaleCancelled() }
                try reportSubprocessFailure(decode: decode, encode: encode)
                throw error
            }
        }

        // The throttle may have swallowed the last few frames' updates.
        report(force: true)
        closePipes()

        progress?(UpscaleProgress(
            phase: .finalizing,
            framesProcessed: framesBefore + writer.framesWritten,
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
