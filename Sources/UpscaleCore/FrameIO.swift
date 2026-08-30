import Foundation

/// Reads fixed-size raw frames off the decode pipe.
///
/// `read(2)` on a pipe returns whatever is buffered, which for a multi-megabyte frame
/// is almost never the whole thing, so every frame is assembled from repeated reads.
public final class FrameReader {
    public let frameByteCount: Int
    private let fileDescriptor: Int32
    private let handle: FileHandle
    private var buffer: [UInt8]
    public private(set) var framesRead = 0

    public init(handle: FileHandle, frameByteCount: Int) {
        precondition(frameByteCount > 0, "frame size must be positive")
        self.handle = handle
        self.fileDescriptor = handle.fileDescriptor
        self.frameByteCount = frameByteCount
        self.buffer = [UInt8](repeating: 0, count: frameByteCount)
    }

    /// Returns the next full frame, or nil at a clean end of stream.
    ///
    /// A partial frame at EOF is an error, not an end: it means ffmpeg died mid-frame.
    public func readFrame() throws -> Data? {
        var filled = 0
        while filled < frameByteCount {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: filled)
                return Darwin.read(fileDescriptor, base, frameByteCount - filled)
            }
            if count > 0 {
                filled += count
                continue
            }
            if count == 0 {
                guard filled == 0 else {
                    throw UpscaleError.processFailed(
                        tool: "frame reader",
                        status: 0,
                        stderr: "decoder ended mid-frame after \(framesRead) frames "
                            + "(\(filled) of \(frameByteCount) bytes)"
                    )
                }
                return nil
            }
            if errno == EINTR { continue }
            throw UpscaleError.processFailed(
                tool: "frame reader",
                status: Int32(errno),
                stderr: String(cString: strerror(errno))
            )
        }
        framesRead += 1
        return Data(buffer)
    }

    public func close() {
        try? handle.close()
    }
}

/// Writes processed frames into the encode pipe.
public final class FrameWriter {
    private let handle: FileHandle
    private let fileDescriptor: Int32
    public private(set) var framesWritten = 0

    public init(handle: FileHandle) {
        self.handle = handle
        self.fileDescriptor = handle.fileDescriptor
        // If ffmpeg dies mid-file, the next write hits a broken pipe. The default
        // SIGPIPE would kill the whole app; this makes the write fail with EPIPE
        // instead, so the real ffmpeg error can be reported. Per-descriptor, so it
        // does not disturb signal handling anywhere else in the process.
        _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    public func write(frame: Data) throws {
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fileDescriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw UpscaleError.processFailed(
                    tool: "frame writer",
                    status: Int32(errno),
                    stderr: count < 0
                        ? String(cString: strerror(errno))
                        : "encoder closed its input after \(framesWritten) frames"
                )
            }
        }
        framesWritten += 1
    }

    /// Signals end of stream so ffmpeg finalises the file.
    public func finish() {
        try? handle.close()
    }
}
