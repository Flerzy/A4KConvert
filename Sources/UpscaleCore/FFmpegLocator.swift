import Foundation

/// Resolved paths to the two ffmpeg binaries the pipeline drives.
public struct FFmpegTools: Equatable, Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }
}

/// Finds `ffmpeg` and `ffprobe`, preferring a copy shipped inside the app bundle.
///
/// Search order is bundle → `/opt/homebrew/bin` → `PATH`. v1 requires a Homebrew
/// install; bundling is a distribution-time concern, so the bundle branch is here
/// only so that adding the binaries later needs no code change.
public enum FFmpegLocator {
    public static let homebrewDirectories = [
        "/opt/homebrew/bin",  // Apple Silicon Homebrew
        "/usr/local/bin",     // Intel Homebrew, and manual installs
    ]

    /// Directories inside an app bundle that a vendored binary could live in.
    static func bundleDirectories(for bundle: Bundle) -> [String] {
        var directories: [String] = []
        if let resources = bundle.resourceURL {
            directories.append(resources.path)
            directories.append(resources.appendingPathComponent("ffmpeg").path)
        }
        if let executable = bundle.executableURL?.deletingLastPathComponent() {
            directories.append(executable.path)
        }
        return directories
    }

    public static func locate(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> FFmpegTools {
        let searchPath = searchDirectories(bundle: bundle, environment: environment)
        return FFmpegTools(
            ffmpeg: try find("ffmpeg", in: searchPath, fileManager: fileManager),
            ffprobe: try find("ffprobe", in: searchPath, fileManager: fileManager)
        )
    }

    static func searchDirectories(bundle: Bundle, environment: [String: String]) -> [String] {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        var directories = bundleDirectories(for: bundle) + homebrewDirectories + pathEntries

        // Keep the first occurrence of each directory so the precedence above holds.
        var seen = Set<String>()
        directories = directories.filter { seen.insert($0).inserted }
        return directories
    }

    static func find(
        _ tool: String,
        in directories: [String],
        fileManager: FileManager
    ) throws -> URL {
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(tool)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path)
            else { continue }
            return candidate
        }
        throw UpscaleError.toolNotFound(tool: tool, searched: directories)
    }
}
