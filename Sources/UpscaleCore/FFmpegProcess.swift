import Foundation

/// A long-running ffmpeg subprocess with pipes the caller streams frames through.
///
/// stderr is always a pipe: it carries both the log (kept as a bounded tail for error
/// reporting) and, when `-progress pipe:2` is passed, the progress records.
public final class FFmpegProcess {
    /// How one of the standard streams is wired up.
    public enum StreamMode {
        /// The caller reads or writes this stream through a `FileHandle`.
        case pipe
        /// `/dev/null`.
        case null
    }

    /// How many stderr lines to keep for error reporting.
    public static let stderrTailLineLimit = 200

    public let label: String
    private let executable: URL
    public let arguments: [String]
    private let inputMode: StreamMode
    private let outputMode: StreamMode

    private let process = Process()
    private let stderrPipe = Pipe()
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?

    private let lock = NSLock()
    private var stderrLines: [String] = []
    private var parser = FFmpegStderrParser()
    private var stderrThread: Thread?
    private let stderrDrained = DispatchSemaphore(value: 0)
    private var started = false

    /// Called on the stderr reader thread whenever a progress record updates.
    public var onProgress: ((FFmpegProgress) -> Void)?

    public init(
        label: String,
        executable: URL,
        arguments: [String],
        standardInput: StreamMode = .null,
        standardOutput: StreamMode = .null
    ) {
        self.label = label
        self.executable = executable
        self.arguments = arguments
        self.inputMode = standardInput
        self.outputMode = standardOutput
    }

    /// Write raw frames here when `standardInput` is `.pipe`.
    public private(set) var inputHandle: FileHandle?
    /// Read raw frames from here when `standardOutput` is `.pipe`.
    public private(set) var outputHandle: FileHandle?

    public var isRunning: Bool { started && process.isRunning }

    public var processIdentifier: Int32 { started ? process.processIdentifier : -1 }

    /// The last `stderrTailLineLimit` non-progress lines ffmpeg emitted.
    public var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrLines.joined(separator: "\n")
    }

    public var progress: FFmpegProgress {
        lock.lock()
        defer { lock.unlock() }
        return parser.progress
    }

    public func start() throws {
        precondition(!started, "\(label) was already started")
        process.executableURL = executable
        process.arguments = arguments
        process.standardError = stderrPipe

        switch inputMode {
        case .pipe:
            let pipe = Pipe()
            inputPipe = pipe
            inputHandle = pipe.fileHandleForWriting
            process.standardInput = pipe
        case .null:
            process.standardInput = FileHandle.nullDevice
        }

        switch outputMode {
        case .pipe:
            let pipe = Pipe()
            outputPipe = pipe
            outputHandle = pipe.fileHandleForReading
            process.standardOutput = pipe
        case .null:
            process.standardOutput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw UpscaleError.processLaunchFailed(
                tool: label,
                underlying: error.localizedDescription
            )
        }
        started = true

        let thread = Thread { [weak self] in self?.drainStandardError() }
        thread.name = "upscale.\(label).stderr"
        thread.start()
        stderrThread = thread
    }

    /// Blocking read loop for stderr, on its own thread.
    ///
    /// A dedicated thread rather than a `readabilityHandler` so that stderr keeps
    /// draining even while the caller's thread is blocked writing a frame — a full
    /// stderr pipe would otherwise deadlock ffmpeg mid-encode.
    private func drainStandardError() {
        let handle = stderrPipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            handleStderr(chunk, isFinal: false)
        }
        handleStderr(Data(), isFinal: true)
        try? handle.close()
        stderrDrained.signal()
    }

    private func handleStderr(_ chunk: Data, isFinal: Bool) {
        lock.lock()
        let previousProgress = parser.progress
        let lines = isFinal ? parser.finish() : parser.consume(chunk)
        if !lines.isEmpty {
            stderrLines.append(contentsOf: lines)
            if stderrLines.count > FFmpegProcess.stderrTailLineLimit {
                stderrLines.removeFirst(stderrLines.count - FFmpegProcess.stderrTailLineLimit)
            }
        }
        let currentProgress = parser.progress
        let callback = onProgress
        lock.unlock()

        if currentProgress != previousProgress {
            callback?(currentProgress)
        }
    }

    /// Closes the input pipe so ffmpeg sees end-of-stream and starts finalising.
    public func closeInput() {
        guard let handle = inputHandle else { return }
        inputHandle = nil
        try? handle.close()
    }

    @discardableResult
    public func waitUntilExit() -> Int32 {
        guard started else { return -1 }
        process.waitUntilExit()
        // Wait for the reader thread so `stderrTail` is complete when we report a failure.
        stderrDrained.wait()
        stderrDrained.signal()
        return process.terminationStatus
    }

    /// Throws with the stderr tail attached when ffmpeg exited non-zero.
    public func waitAndCheck() throws {
        let status = waitUntilExit()
        guard status == 0 else {
            throw UpscaleError.processFailed(tool: label, status: status, stderr: stderrTail)
        }
    }

    /// SIGTERM, then SIGKILL if ffmpeg has not exited within `grace` seconds.
    ///
    /// Deliberately does not touch the pipe handles: another thread may be blocked
    /// reading or writing one, and closing the descriptor out from under it turns a
    /// clean cancellation into a spurious `EBADF`. ffmpeg exiting closes its ends,
    /// which is what unblocks that thread; the owner closes ours afterwards.
    public func terminate(grace: TimeInterval = 2) {
        guard started, process.isRunning else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
