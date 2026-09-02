import Foundation
import Metal

/// One entry in the queue, with everything the UI shows about it.
public struct QueuedJob: Identifiable, Equatable {
    public enum State: Equatable {
        case probing
        case queued
        case running
        case finished
        case failed
        case cancelled

        public var isTerminal: Bool {
            switch self {
            case .finished, .failed, .cancelled: return true
            case .probing, .queued, .running: return false
            }
        }
    }

    public let id: UUID
    public let input: URL
    public var media: MediaInfo?
    public var settings: UpscaleJobSettings
    /// Ranges the chapter detector proposed. Listed in the row whether or not they are
    /// checked, so the user can toggle one back on without retyping its times.
    public var detectedSkipRanges: [SkipRange] = []
    public var state: State
    public var progress: UpscaleProgress?
    /// One-line reason, suitable for the row.
    public var failureMessage: String?
    /// The full ffmpeg/Metal output behind `failureMessage`, for the disclosure view.
    public var failureDetail: String?

    public init(input: URL, settings: UpscaleJobSettings) {
        self.id = UUID()
        self.input = input
        self.settings = settings
        self.state = .probing
    }

    public var displayName: String { input.lastPathComponent }

    /// e.g. "1920x1080 → 3840x2160".
    public var resolutionSummary: String? {
        guard let media else { return nil }
        let width = media.video.width * settings.scale
        let height = media.video.height * settings.scale
        return "\(media.video.width)x\(media.video.height) → \(width)x\(height)"
    }

    /// e.g. "Skipping 2 segments (3:00.0)"; nil when nothing is skipped.
    public var skipSummary: String? {
        let ranges = SkipRanges.normalized(settings.skipRanges, duration: media?.duration)
        guard !ranges.isEmpty else { return nil }
        let total = Timecode.format(SkipRanges.totalDuration(ranges))
        return ranges.count == 1
            ? "Skipping 1 segment (\(total))"
            : "Skipping \(ranges.count) segments (\(total))"
    }

    /// Every range the row can show: the detected ones plus any the user typed.
    public var allSkipRanges: [SkipRange] {
        var ranges = detectedSkipRanges
        for chosen in settings.skipRanges
        where !ranges.contains(where: { $0.coversSameTime(as: chosen) }) {
            ranges.append(chosen)
        }
        return ranges.sorted { $0.start < $1.start }
    }

    public func isSkipRangeEnabled(_ range: SkipRange) -> Bool {
        settings.skipRanges.contains { $0.coversSameTime(as: range) }
    }
}

/// Runs queued jobs one at a time and publishes their progress on the main actor.
///
/// All the work lives here rather than in the views: the UI only observes `jobs`.
@MainActor
public final class JobQueue: ObservableObject {
    @Published public private(set) var jobs: [QueuedJob] = []
    @Published public private(set) var isRunning = false
    /// Set when ffmpeg or Metal could not be found at all, which blocks everything.
    @Published public private(set) var environmentError: String?
    /// What a newly added file starts with. The app persists this; the core only uses it.
    @Published public var defaults: JobDefaults

    private let tools: FFmpegTools?
    private let device: MTLDevice?
    private let catalog: ShaderCatalog
    private let workQueue = DispatchQueue(label: "upscale.job-queue", qos: .userInitiated)
    private var runningJob: UpscaleJob?
    /// Ids of running jobs the user has cancelled, so their failure is labelled right.
    private var cancelledIDs: Set<UUID> = []
    /// True between pressing Start and the queue genuinely running dry. Lets a job that
    /// was still being probed when the queue drained pick up where it left off, without
    /// ever starting work the user did not ask for.
    private var wantsToRun = false

    public init(catalog: ShaderCatalog = ShaderCatalog(), defaults: JobDefaults = .standard) {
        self.catalog = catalog
        self.defaults = defaults
        let tools = try? FFmpegLocator.locate()
        let device = MTLCreateSystemDefaultDevice()
        self.tools = tools
        self.device = device

        if tools == nil {
            environmentError = "ffmpeg and ffprobe were not found. Install them with "
                + "`brew install ffmpeg`, then reopen Upscale."
        } else if device == nil {
            environmentError = "No Metal device is available on this machine."
        }
    }

    public var canRun: Bool { environmentError == nil }

    // MARK: - Queue management

    /// Adds files, probing each in the background so the row can show its details.
    public func add(_ urls: [URL]) {
        guard let tools else { return }
        for url in urls {
            var job = QueuedJob(input: url, settings: defaults.settings(for: url))
            job.state = .probing
            jobs.append(job)
            let id = job.id

            workQueue.async {
                let result = Result { try Probe(tools: tools).probe(url: url) }
                Task { @MainActor in
                    self.applyProbe(result, to: id)
                }
            }
        }
    }

    private func applyProbe(_ result: Result<MediaInfo, Error>, to id: UUID) {
        // The row may have been cancelled or removed while the probe was in flight;
        // applying the result then would put a cancelled job back in the queue.
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .probing
        else { return }

        switch result {
        case let .success(media):
            jobs[index].media = media
            let detected = ChapterSkipDetector.skippableRanges(in: media)
            jobs[index].detectedSkipRanges = detected
            if defaults.autoSkipChapters {
                jobs[index].settings.skipRanges = detected
            }
            if let reason = media.rejectionReason() {
                jobs[index].state = .failed
                jobs[index].failureMessage = reason
            } else {
                jobs[index].state = .queued
                // The queue may have run dry waiting for exactly this probe.
                if wantsToRun, runningJob == nil {
                    runNextJob()
                }
            }
        case let .failure(error):
            jobs[index].state = .failed
            let failure = JobQueue.describe(error)
            jobs[index].failureMessage = failure.message
            jobs[index].failureDetail = failure.detail
        }
    }

    public func remove(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state != .running else { return }
        jobs.remove(at: index)
    }

    public func removeFinished() {
        jobs.removeAll { $0.state.isTerminal }
    }

    public func update(_ id: UUID, _ change: (inout UpscaleJobSettings) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              !jobs[index].state.isTerminal, jobs[index].state != .running
        else { return }
        change(&jobs[index].settings)
    }

    /// Copies one row's preset, scale, encoder and output *folder* onto every queued row.
    ///
    /// The file name is deliberately not copied: each target recomputes its own from its
    /// own input, so a batch never collapses onto a single destination file.
    public func applyToAllQueued(from id: UUID) {
        guard let source = jobs.first(where: { $0.id == id })?.settings else { return }
        let folder = source.output.deletingLastPathComponent()
        for index in jobs.indices where jobs[index].state == .queued && jobs[index].id != id {
            jobs[index].settings.preset = source.preset
            jobs[index].settings.scale = source.scale
            jobs[index].settings.encoder = source.encoder
            jobs[index].settings.container = source.container
            jobs[index].settings.output = JobDefaults.outputURL(
                for: jobs[index].input, scale: source.scale, in: folder
            )
        }
    }

    /// Copies one row's checked skip ranges onto every other queued row.
    ///
    /// Separate from `applyToAllQueued` because it only makes sense across episodes of
    /// the same show, where the OP and ED sit at the same timestamps.
    public func copySkipRangesToAllQueued(from id: UUID) {
        guard let ranges = jobs.first(where: { $0.id == id })?.settings.skipRanges else { return }
        for index in jobs.indices where jobs[index].state == .queued && jobs[index].id != id {
            jobs[index].settings.skipRanges = ranges
        }
    }

    /// Adds a range the user typed, or removes the one covering the same time.
    public func setSkipRange(_ range: SkipRange, enabled: Bool, for id: UUID) {
        update(id) { settings in
            settings.skipRanges.removeAll { $0.coversSameTime(as: range) }
            if enabled {
                settings.skipRanges.append(range)
                settings.skipRanges.sort { $0.start < $1.start }
            }
        }
    }

    /// Makes one row's settings the defaults new files get.
    ///
    /// The output folder is only remembered when it is not the input's own folder;
    /// otherwise the default stays "beside the input", which is what the user picked
    /// implicitly by never choosing a destination.
    public func makeDefaults(from id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let folder = job.settings.output.deletingLastPathComponent()
        let besideInput = job.input.deletingLastPathComponent()
        defaults = JobDefaults(
            presetID: job.settings.preset.id,
            scale: job.settings.scale,
            encoder: job.settings.encoder.encoder,
            quality: job.settings.encoder.quality,
            outputFolder: JobQueue.isSameFolder(folder, besideInput) ? nil : folder,
            autoSkipChapters: defaults.autoSkipChapters
        )
    }

    private static func isSameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL
            == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Puts a finished, failed or cancelled job back in line.
    public func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isTerminal
        else { return }
        // Otherwise a stale cancellation would mislabel this run's outcome.
        cancelledIDs.remove(id)
        jobs[index].state = .queued
        jobs[index].progress = nil
        jobs[index].failureMessage = nil
        jobs[index].failureDetail = nil
    }

    // MARK: - Running

    public func start() {
        guard canRun, !isRunning else { return }
        wantsToRun = true
        runNextJob()
    }

    public func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .running:
            // Only a running job reaches `finish`, so only its id needs remembering.
            cancelledIDs.insert(id)
            // Terminating walks a grace period waiting for ffmpeg to exit; doing that
            // on the main actor would freeze the window for seconds. It cannot go on
            // `workQueue` either — that is serial and currently busy with this job.
            let job = runningJob
            DispatchQueue.global(qos: .userInitiated).async { job?.cancel() }
        case .queued, .probing:
            jobs[index].state = .cancelled
        case .finished, .failed, .cancelled:
            break
        }
    }

    public func cancelAll() {
        wantsToRun = false
        for job in jobs where !job.state.isTerminal {
            cancel(job.id)
        }
    }

    private func runNextJob() {
        guard let tools, let device else { return }
        guard let index = jobs.firstIndex(where: { $0.state == .queued }) else {
            runningJob = nil
            // Stay "running" while a probe is still outstanding: that job is about to
            // become queued, and `applyProbe` will start it.
            if wantsToRun, jobs.contains(where: { $0.state == .probing }) {
                isRunning = true
                return
            }
            wantsToRun = false
            isRunning = false
            return
        }

        isRunning = true
        jobs[index].state = .running
        jobs[index].progress = UpscaleProgress(phase: .probing)
        let id = jobs[index].id
        let input = jobs[index].input
        let settings = jobs[index].settings

        let job = UpscaleJob(
            input: input,
            settings: settings,
            tools: tools,
            device: device,
            catalog: catalog
        )
        runningJob = job

        workQueue.async {
            let outcome = Result {
                try job.run { progress in
                    Task { @MainActor in
                        self.applyProgress(progress, to: id)
                    }
                }
            }
            Task { @MainActor in
                self.finish(id: id, outcome: outcome)
            }
        }
    }

    private func applyProgress(_ progress: UpscaleProgress, to id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running
        else { return }
        jobs[index].progress = progress
    }

    private func finish(id: UUID, outcome: Result<MediaInfo, Error>) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            switch outcome {
            case .success:
                jobs[index].state = .finished
            case let .failure(error):
                if error is UpscaleCancelled || cancelledIDs.contains(id) {
                    jobs[index].state = .cancelled
                } else {
                    jobs[index].state = .failed
                    let failure = JobQueue.describe(error)
                    jobs[index].failureMessage = failure.message
                    jobs[index].failureDetail = failure.detail
                }
            }
        }
        cancelledIDs.remove(id)
        runningJob = nil
        runNextJob()
    }

    // MARK: - Error presentation

    /// Splits an error into a one-line summary and the raw tool output behind it.
nonisolated static func describe(_ error: Error) -> (message: String, detail: String?) {
        switch error {
        case let upscaleError as UpscaleError:
            if case let .processFailed(_, _, stderr) = upscaleError {
                return (upscaleError.description, stderr.isEmpty ? nil : stderr)
            }
            return (upscaleError.description, nil)
        case let shaderError as ShaderError:
            if case let .compilationFailed(_, message) = shaderError {
                return ("A shader failed to compile.", message)
            }
            return (shaderError.description, nil)
        case let engineError as EngineError:
            return (engineError.description, nil)
        case let mismatch as FrameCountMismatch:
            return (mismatch.description, nil)
        default:
            return (String(describing: error), nil)
        }
    }
}
