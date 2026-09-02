import XCTest
@testable import UpscaleCore

/// Covers the queue state machine, including the transitions a background probe
/// racing against the user's cancel can produce.
@MainActor
final class JobQueueTests: XCTestCase {
    private func makeQueue() throws -> JobQueue {
        _ = try TestSupport.requireTools()
        let queue = JobQueue()
        guard queue.canRun else {
            throw XCTSkip("ffmpeg or Metal unavailable: \(queue.environmentError ?? "")")
        }
        return queue
    }

    /// Waits for every row to leave `.probing`, since probing is done off the main actor.
    private func waitForProbes(_ queue: JobQueue, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while queue.jobs.contains(where: { $0.state == .probing }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testProbeDoesNotResurrectACancelledJob() throws {
        let queue = try makeQueue()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5),
            in: directory
        )

        queue.add([fixture])
        let id = try XCTUnwrap(queue.jobs.first?.id)
        XCTAssertEqual(queue.jobs[0].state, .probing)

        // Cancel while the probe is still in flight.
        queue.cancel(id)
        XCTAssertEqual(queue.jobs[0].state, .cancelled)

        // Let the probe land; it must not put the job back in the queue.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(queue.jobs[0].state, .cancelled)
        XCTAssertNil(queue.jobs[0].media)
    }

    /// A job cancelled before it ran, then retried, must be able to fail properly.
    func testRetryAfterCancelClearsTheCancellationMark() throws {
        let queue = try makeQueue()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5),
            in: directory
        )

        queue.add([fixture])
        waitForProbes(queue)
        let id = try XCTUnwrap(queue.jobs.first?.id)
        XCTAssertEqual(queue.jobs[0].state, .queued)

        queue.cancel(id)
        XCTAssertEqual(queue.jobs[0].state, .cancelled)
        queue.retry(id)
        XCTAssertEqual(queue.jobs[0].state, .queued)

        // Make it fail for a real reason, and check the failure is reported as such.
        queue.update(id) { $0.output = URL(fileURLWithPath: "/upscale-not-writable/out.mkv") }
        queue.start()

        let deadline = Date().addingTimeInterval(120)
        while !queue.jobs[0].state.isTerminal, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(queue.jobs[0].state, .failed)
        XCTAssertNotNil(queue.jobs[0].failureMessage)
    }

    func testCancellingAQueuedJobDoesNotStartIt() throws {
        let queue = try makeQueue()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5),
            in: directory
        )
        queue.add([fixture])
        waitForProbes(queue)

        let id = try XCTUnwrap(queue.jobs.first?.id)
        queue.cancelAll()
        XCTAssertEqual(queue.jobs[0].state, .cancelled)
        queue.start()
        XCTAssertFalse(queue.isRunning)
        _ = id
    }

    func testNewJobsStartFromTheDefaults() throws {
        _ = try TestSupport.requireTools()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputFolder = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5),
            in: directory
        )

        let defaults = JobDefaults(
            presetID: "mode-a-fast", scale: 4, encoder: .h264, quality: 40,
            outputFolder: outputFolder
        )
        let queue = JobQueue(defaults: defaults)
        try XCTSkipUnless(queue.canRun, queue.environmentError ?? "")
        queue.add([fixture])

        let settings = queue.jobs[0].settings
        XCTAssertEqual(settings.preset.id, "mode-a-fast")
        XCTAssertEqual(settings.scale, 4)
        XCTAssertEqual(settings.encoder.encoder, .h264)
        XCTAssertEqual(settings.encoder.quality, 40)
        XCTAssertEqual(settings.output, outputFolder.appendingPathComponent("fixture.4x.mkv"))
    }

    /// A batch has to share settings but keep one file per input.
    func testApplyToAllQueuedSharesSettingsButNotTheFileName() throws {
        let queue = try makeQueue()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spec = TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5)
        let first = try TestSupport.makeFixture(spec, in: directory, name: "ep1")
        let second = try TestSupport.makeFixture(spec, in: directory, name: "ep2")

        queue.add([first, second])
        waitForProbes(queue)
        XCTAssertEqual(queue.jobs.map(\.state), [.queued, .queued])

        let sourceID = queue.jobs[0].id
        let outputFolder = directory.appendingPathComponent("out", isDirectory: true)
        queue.update(sourceID) { settings in
            settings.preset = Preset.preset(id: "mode-a-hq")!
            settings.scale = 4
            settings.encoder = EncoderSettings(encoder: .h264, quality: 30)
            settings.output = outputFolder.appendingPathComponent("anything.mkv")
        }
        queue.applyToAllQueued(from: sourceID)

        let target = queue.jobs[1].settings
        XCTAssertEqual(target.preset.id, "mode-a-hq")
        XCTAssertEqual(target.scale, 4)
        XCTAssertEqual(target.encoder, EncoderSettings(encoder: .h264, quality: 30))
        XCTAssertEqual(target.output, outputFolder.appendingPathComponent("ep2.4x.mkv"))
        // The source keeps the name the user chose for it.
        XCTAssertEqual(
            queue.jobs[0].settings.output, outputFolder.appendingPathComponent("anything.mkv")
        )
        XCTAssertNotEqual(queue.jobs[0].settings.output, queue.jobs[1].settings.output)
    }

    func testMakeDefaultsCopiesTheRowsSettings() throws {
        let queue = try makeQueue()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5),
            in: directory
        )
        queue.add([fixture])
        waitForProbes(queue)
        let id = queue.jobs[0].id

        // An output left beside the input must not turn into a pinned folder.
        queue.update(id) { $0.scale = 4 }
        queue.makeDefaults(from: id)
        XCTAssertEqual(queue.defaults.scale, 4)
        XCTAssertNil(queue.defaults.outputFolder)

        let outputFolder = directory.appendingPathComponent("out", isDirectory: true)
        queue.update(id) { settings in
            settings.encoder = EncoderSettings(encoder: .h264, quality: 30)
            settings.output = outputFolder.appendingPathComponent("chosen.mkv")
        }
        queue.makeDefaults(from: id)
        XCTAssertEqual(queue.defaults.encoder, .h264)
        XCTAssertEqual(queue.defaults.quality, 30)
        XCTAssertEqual(queue.defaults.outputFolder, outputFolder)
    }

    func testFailedProbeSurfacesTheFFmpegMessage() throws {
        let queue = try makeQueue()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notVideo = directory.appendingPathComponent("notes.txt")
        try "hello".write(to: notVideo, atomically: true, encoding: .utf8)

        queue.add([notVideo])
        waitForProbes(queue)
        XCTAssertEqual(queue.jobs[0].state, .failed)
        XCTAssertNotNil(queue.jobs[0].failureMessage)
    }

    func testTenBitProbeFailsTheRowWithoutRunning() throws {
        let queue = try makeQueue()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var spec = TestSupport.FixtureSpec()
        spec.width = 160
        spec.height = 120
        spec.durationSeconds = 0.5
        spec.pixelFormat = "yuv420p10le"
        spec.videoCodec = "libx265"
        spec.includeSubtitles = false
        spec.extraOutputArguments = ["-x265-params", "log-level=none"]
        let fixture = try TestSupport.makeFixture(spec, in: directory)

        queue.add([fixture])
        waitForProbes(queue)
        XCTAssertEqual(queue.jobs[0].state, .failed)
        XCTAssertTrue(
            queue.jobs[0].failureMessage?.contains("10-bit") == true,
            queue.jobs[0].failureMessage ?? "nil"
        )
    }
}

final class OutputDestinationTests: XCTestCase {
    /// Anything that is not MP4/MOV is written as Matroska, so the default name has to
    /// say `.mkv` rather than echo an extension we are not going to honour.
    func testDefaultOutputExtensionFollowsTheContainerWeActuallyWrite() {
        let cases: [(String, String)] = [
            ("/v/show.mkv", "/v/show.2x.mkv"),
            ("/v/show.mp4", "/v/show.2x.mp4"),
            ("/v/show.mov", "/v/show.2x.mov"),
            ("/v/show.m4v", "/v/show.2x.mp4"),
            ("/v/show.avi", "/v/show.2x.mkv"),
            ("/v/show.ts", "/v/show.2x.mkv"),
            ("/v/show.webm", "/v/show.2x.mkv"),
            ("/v/show", "/v/show.2x.mkv"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                UpscaleJobSettings.defaultOutputURL(
                    for: URL(fileURLWithPath: input), scale: 2
                ).path,
                expected,
                input
            )
        }
    }

    func testWritingOverTheInputIsRefused() throws {
        let tools = try TestSupport.requireTools()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try TestSupport.makeFixture(
            TestSupport.FixtureSpec(width: 160, height: 120, durationSeconds: 0.5),
            in: directory
        )
        let before = try Data(contentsOf: fixture).count

        let job = try UpscaleJob(
            input: fixture,
            settings: UpscaleJobSettings(scale: 2, output: fixture)
        )
        XCTAssertThrowsError(try job.run()) { error in
            guard case UpscaleError.outputWouldOverwriteInput = error else {
                return XCTFail("expected outputWouldOverwriteInput, got \(error)")
            }
        }
        // The source must be untouched.
        XCTAssertEqual(try Data(contentsOf: fixture).count, before)
        _ = tools
    }
}

final class SubtitleMappingTests: XCTestCase {
    private func media(subtitleCodecs: [String]) -> MediaInfo {
        MediaInfo(
            path: "in.mkv",
            formatName: "matroska,webm",
            duration: 10,
            video: VideoStream(
                index: 0, codec: "h264", width: 640, height: 480, pixelFormat: "yuv420p",
                bitDepth: 8, realFrameRate: Rational(25, 1), averageFrameRate: Rational(25, 1),
                sampleAspectRatio: .one, nominalFrameCount: 250, duration: 10,
                colorRange: nil, colorSpace: nil, colorPrimaries: nil, colorTransfer: nil
            ),
            audioStreams: [],
            subtitleStreams: subtitleCodecs.enumerated().map { index, codec in
                MediaStream(index: index + 1, kind: .subtitle, codec: codec)
            },
            attachmentStreams: []
        )
    }

    /// Matroska needs two codecs at once for a mixed file; collapsing to one used to
    /// drop every subtitle track instead.
    func testMatroskaSpellsCodecsPerStreamWhenTheyDiffer() {
        let arguments = EncodeProcess.subtitleArguments(
            for: media(subtitleCodecs: ["mov_text", "subrip", "hdmv_pgs_subtitle"]),
            container: .matroska
        )
        XCTAssertEqual(
            arguments,
            ["-map", "1:s?", "-c:s:0", "srt", "-c:s:1", "copy", "-c:s:2", "copy"]
        )
    }

    func testMatroskaUsesASingleCodecWhenAllStreamsAgree() {
        XCTAssertEqual(
            EncodeProcess.subtitleArguments(
                for: media(subtitleCodecs: ["subrip", "ass"]), container: .matroska
            ),
            ["-map", "1:s?", "-c:s", "copy"]
        )
    }

    func testMP4ConvertsTextSubtitles() {
        XCTAssertEqual(
            EncodeProcess.subtitleArguments(
                for: media(subtitleCodecs: ["subrip"]), container: .mp4
            ),
            ["-map", "1:s?", "-c:s", "mov_text"]
        )
    }

    /// Bitmap subtitles have no MP4 representation, and keeping only some tracks would
    /// silently lose the others, so none are mapped.
    func testMP4DropsSubtitlesItCannotCarry() {
        XCTAssertEqual(
            EncodeProcess.subtitleArguments(
                for: media(subtitleCodecs: ["subrip", "hdmv_pgs_subtitle"]), container: .mp4
            ),
            []
        )
    }

    func testNoSubtitlesMeansNoArguments() {
        XCTAssertEqual(
            EncodeProcess.subtitleArguments(for: media(subtitleCodecs: []), container: .matroska),
            []
        )
    }
}
