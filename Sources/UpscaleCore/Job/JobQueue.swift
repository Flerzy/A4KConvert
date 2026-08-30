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

    private let tools: FFmpegTools?
    private let device: MTLDevice?
    private let catalog: ShaderCatalog
    private let workQueue = DispatchQueue(label: "upscale.job-queue", qos: .userInitiated)
    private var runningJob: UpscaleJob?
    private var cancelledIDs: Set<UUID> = []

    public init(catalog: ShaderCatalog = ShaderCatalog()) {
        self.catalog = catalog
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
            var job = QueuedJob(
                input: url,
                settings: UpscaleJobSettings(
                    output: UpscaleJobSettings.defaultOutputURL(for: url, scale: 2)
                )
            )
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
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case let .success(media):
            jobs[index].media = media
            if let reason = media.rejectionReason() {
                jobs[index].state = .failed
                jobs[index].failureMessage = reason
            } else {
                jobs[index].state = .queued
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

    /// Puts a finished, failed or cancelled job back in line.
    public func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isTerminal
        else { return }
        jobs[index].state = .queued
        jobs[index].progress = nil
        jobs[index].failureMessage = nil
        jobs[index].failureDetail = nil
    }

    // MARK: - Running

    public func start() {
        guard canRun, !isRunning else { return }
        runNextJob()
    }

    public func cancel(_ id: UUID) {
        cancelledIDs.insert(id)
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            if jobs[index].state == .running {
                runningJob?.cancel()
            } else if jobs[index].state == .queued || jobs[index].state == .probing {
                jobs[index].state = .cancelled
            }
        }
    }

    public func cancelAll() {
        for job in jobs where !job.state.isTerminal {
            cancel(job.id)
        }
    }

    private func runNextJob() {
        guard let tools, let device else { return }
        guard let index = jobs.firstIndex(where: { $0.state == .queued }) else {
            isRunning = false
            runningJob = nil
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
