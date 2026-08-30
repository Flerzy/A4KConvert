import Foundation

/// Result of a subprocess that we run to completion and fully buffer.
public struct ProcessResult {
    public let terminationStatus: Int32
    public let standardOutputData: Data
    public let standardErrorData: Data

    public var standardOutput: String { String(decoding: standardOutputData, as: UTF8.self) }
    public var standardError: String { String(decoding: standardErrorData, as: UTF8.self) }
}

/// Runs a short-lived subprocess whose entire output fits comfortably in memory.
///
/// Only for tools like `ffprobe`. The frame-carrying ffmpeg processes stream through
/// `FFmpegProcess` instead, because buffering raw video would not fit.
public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UpscaleError.processLaunchFailed(
                tool: executable.lastPathComponent,
                underlying: error.localizedDescription
            )
        }

        // Drain both pipes on their own threads: a process that fills the 64 KB pipe
        // buffer on one of them blocks forever if we read them one after the other.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "upscale.process-runner", attributes: .concurrent)

        queue.async(group: group) {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        queue.async(group: group) {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        process.waitUntilExit()
        group.wait()

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutputData: outData,
            standardErrorData: errData
        )
    }
}
