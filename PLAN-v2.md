# Upscale v2 — Improvement plan

Overseer plan for the second round of work. Each work package (WP) is a self-contained
brief for an implementation model. Read **Ground rules** and **Current architecture**
before starting any WP, then read only the WP you were assigned. `PLAN.md` describes
v1 and is still accurate for everything this plan does not change.

## Ground rules

1. One WP per branch/PR. Do not start a WP on top of another WP's failing checks.
2. Before writing code, run `swift test` and confirm it is green. After the WP, run it
   again plus every command listed under the WP's **Acceptance**. Paste the exact
   output of the acceptance commands in the PR description.
3. All logic goes in `Sources/UpscaleCore`. `App/Upscale` is a thin SwiftUI layer that
   only observes `JobQueue` and calls its methods. If you find yourself writing an
   `if`/loop in a view that decides *what* happens rather than *how it looks*, move it
   into the core and test it there.
4. No silent fallbacks. Missing tool, failed compile, mismatched frame count: throw with
   the shortest decisive message. Never swallow an error to keep going.
5. Keep existing public API working unless the WP says otherwise. New settings fields
   get a default value so existing call sites and tests still compile.
6. Every new behaviour gets a test in `Tests/UpscaleCoreTests`. Tests that need ffmpeg
   call `TestSupport.requireTools()` and build their media with
   `TestSupport.makeFixture(...)`; no binary media is committed.
7. Do not add third-party Swift packages. Do not add new external binaries beyond
   ffmpeg/ffprobe.
8. Keep comments in the existing style: explain *why*, not *what*. Keep the Apache-2.0
   headers on ported files.
9. Update `README.md` (scope section) and `docs/manual-test.md` when a WP changes what
   the user can do.
10. Commit messages: Conventional Commits (`feat:`, `fix:`, `perf:`, `test:`, `docs:`).

## Current architecture (v1, as shipped)

```
input → ffmpeg decode (-pix_fmt bgra, cfr) → FrameReader → MTLTexture (bgra8Unorm, shared)
      → Anime4KEngine.encode (passes… → optional Lanczos → resolve kernel)
      → FrameTextures.readback → FrameWriter → ffmpeg encode (rawvideo bgra → VideoToolbox) → output
```

Key files and the roles they play:

| File | Role |
| --- | --- |
| `Sources/UpscaleCore/Probe.swift`, `FFprobeJSON.swift`, `MediaInfo.swift` | Run ffprobe, decode its JSON, expose `MediaInfo` (streams, fps, colour tags, `rejectionReason()`). |
| `Sources/UpscaleCore/DecodeProcess.swift` | ffmpeg #1 argument list. Emits raw frames on stdout. |
| `Sources/UpscaleCore/EncodeProcess.swift`, `EncoderSettings.swift`, `ColorProperties.swift`, `OutputContainer.swift` | ffmpeg #2 argument list: `EncodePlan`, encoder flags, colour filters, stream mapping. |
| `Sources/UpscaleCore/FrameIO.swift`, `RawFrameFormat.swift` | `FrameReader`/`FrameWriter` over the pipes; the pixel layout on the pipe. |
| `Sources/UpscaleCore/Engine/Anime4KEngine.swift`, `RenderPlan.swift`, `TexturePool.swift`, `FrameTextures.swift`, `ResolveKernel.swift` | Metal side. `configure(inputSize:targetSize:)` compiles pipelines; `encode(commandBuffer:input:output:)` runs one frame. |
| `Sources/UpscaleCore/Shaders/*` | GLSL parser, MSL translator, `Preset`, `ShaderCatalog`. |
| `Sources/UpscaleCore/Job/UpscaleJob.swift` | One file end to end. `runPipeline` keeps up to `inFlightFrameLimit` (4) frames on the GPU and drains them FIFO with `waitUntilCompleted`. |
| `Sources/UpscaleCore/Job/UpscaleJobSettings.swift` | `UpscaleJobSettings`, `UpscaleProgress`, `UpscaleJobPhase`. |
| `Sources/UpscaleCore/Job/JobQueue.swift` | `@MainActor` queue: probe on add, run sequentially, publish `QueuedJob` rows. |
| `App/Upscale/JobRow.swift`, `ContentView.swift`, `JobQueue+OpenPanel.swift` | The UI. |
| `Tests/UpscaleCoreTests/TestSupport.swift` | `FixtureSpec` + `makeFixture` synthesise test media with ffmpeg; `ffprobe` helpers. |

Useful commands:

```sh
swift test                                                     # core library, ~1-2 min
UPSCALE_BENCHMARK=1 swift test --filter EngineBenchmarkTests    # throughput report
UPSCALE_MATRIX=1 swift test --filter MatrixTests                # slow container/codec matrix
xcodebuild -project App/Upscale.xcodeproj -scheme Upscale build # the app
```

## Work package order

Do them in this order. Later WPs assume earlier ones are merged.

| WP | Title | Size |
| --- | --- | --- |
| WP7 | Persisted defaults and batch apply | S |
| WP8 | Skip intro/outro (passthrough segments) | M |
| WP9 | In-process pipeline cache | S |
| WP10 | Pipeline overlap and hardware decode | M |
| WP11 | `yuv420p` on the pipes, colour conversion in Metal | M |
| WP12 | 10-bit SDR input and output | M |
| WP13 | Modes B, C, B+B, C+A | S |
| WP14 | Before/after preview | M |
| WP15 | Software encoders and encoder options | M |
| WP16 | Target-height scaling | S |
| WP17 | Robustness and small UX | M (split into independent items) |
| WP18 | Command-line target | S |
| WP19 | Bundled ffmpeg for distribution | M |
| WP20 | Cross-episode audio matching for skip ranges | L — **deferred, spec only** |

---

## WP7 — Persisted defaults and batch apply

Nothing is remembered between launches today, and every row has to be configured by
hand. Fix both.

**Deliverables**

- New `Sources/UpscaleCore/Job/JobDefaults.swift`:
  ```swift
  public struct JobDefaults: Equatable, Sendable {
      public var presetID: String            // Preset.default.id
      public var scale: Int                  // 2
      public var encoder: VideoEncoder       // .hevc
      public var quality: Int                // EncoderSettings.defaultQuality
      public var outputFolder: URL?          // nil = beside the input
      public var autoSkipChapters: Bool      // true (consumed by WP8)
      public static let standard: JobDefaults
      public func settings(for input: URL) -> UpscaleJobSettings
  }
  ```
  `settings(for:)` builds the `UpscaleJobSettings` a newly added file gets. When
  `outputFolder` is set, the output is `<folder>/<base>.<scale>x.<ext>`; otherwise use
  the existing `UpscaleJobSettings.defaultOutputURL(for:scale:)`. If `presetID` is
  unknown (e.g. renamed), fall back to `Preset.default`.
- `JobQueue`:
  - `@Published public var defaults: JobDefaults` (initialised from an injected value,
    default `.standard`). `add(_:)` uses `defaults.settings(for:)`.
  - `public func applyToAllQueued(from id: UUID)`: copies `preset`, `scale`, `encoder`
    and the output *folder* (not the file name) of job `id` onto every job whose state
    is `.queued`. Each target recomputes its own output file name from its own input.
  - `public func makeDefaults(from id: UUID)`: sets `defaults` from that job's settings.
- Persistence lives in the app, not the core: `App/Upscale/DefaultsStore.swift` reads
  and writes `JobDefaults` to `UserDefaults.standard` under keys prefixed `defaults.`
  (`defaults.presetID`, `defaults.scale`, …). The app initialises `JobQueue` from it
  and writes back whenever `queue.defaults` changes (`onChange` / Combine sink). Store
  `outputFolder` as a path string; the app is not sandboxed, so no bookmarks needed.
- UI in `JobRow`: a small `Menu` (ellipsis button) on each queued row with
  "Apply These Settings to All Queued" and "Use These Settings as Default". A
  "Default output folder…" button in the toolbar that opens `NSOpenPanel` in
  directory mode and a "Reset to beside input" item.

**Acceptance**

- `JobQueueTests`: adding two files then `applyToAllQueued(from:)` gives both the same
  preset/scale/encoder and *different* output file names in the same folder.
- `JobDefaults.settings(for:)` unit tests: folder set / not set, unknown preset id.
- `swift test` green; app builds; `docs/manual-test.md` gains a "Defaults" section.

---

## WP8 — Skip intro/outro (passthrough segments)

The user can mark time ranges (typically the OP and ED of an episode) that are
**not** run through the Anime4K chain. Those frames are still decoded, still
upscaled to the target size with a plain Lanczos resample, and still encoded, so the
output keeps its full length, audio sync, subtitles and chapters. Only the expensive
part is skipped. Ranges come from Matroska chapter names automatically, or from the
user by hand. Cutting the ranges out of the file is **out of scope** and must not be
built.

### 8.1 Core model

New file `Sources/UpscaleCore/Job/SkipRanges.swift`:

```swift
/// A half-open interval of source time, in seconds.
public struct SkipRange: Equatable, Hashable, Sendable, Codable {
    public var start: Double
    public var end: Double          // exclusive; must be > start
    public var label: String?       // e.g. the chapter title it came from
    public init(start: Double, end: Double, label: String? = nil)
}

public enum SkipRanges {
    /// Sorts, clamps to [0, duration] when duration is known, drops empty or inverted
    /// ranges, merges overlapping or touching ones.
    public static func normalized(_ ranges: [SkipRange], duration: Double?) -> [SkipRange]
}

/// Frame-level view of the ranges, built once per job.
public struct SkipPlan: Equatable, Sendable {
    public let frameRanges: [Range<Int>]     // sorted, disjoint
    public init(ranges: [SkipRange], frameRate: Rational)
    /// Frame index → seconds is `Double(index) * frameRate.denominator / frameRate.numerator`.
    /// A frame is skipped when its timestamp t satisfies start <= t < end.
    /// Equivalent: firstFrame = ceil(start * fps), endFrame = ceil(end * fps), exclusive.
    public func isSkipped(frame index: Int) -> Bool     // binary search; O(log n)
    public var skippedFrameCount: Int
}
```

`UpscaleJobSettings` gains `public var skipRanges: [SkipRange] = []`. The decode side
already forces constant frame rate at `media.video.realFrameRate`, so frame `i`'s time
is exactly `i / realFrameRate`. Use that rate, never `averageFrameRate`.

### 8.2 Chapters from ffprobe

- `Probe.arguments(for:)` adds `-show_chapters`.
- `FFprobeJSON.swift`: `FFprobeOutput.chapters: [FFprobeChapter]?` with
  `id`, `@LenientNumber start_time`, `@LenientNumber end_time`, `tags`. ffprobe writes
  `start_time`/`end_time` as strings of seconds.
- `MediaInfo.chapters: [Chapter]` where
  `public struct Chapter: Equatable, Sendable { start: Double; end: Double; title: String? }`.
  Give the `MediaInfo` initialiser a default `chapters: [] ` so existing tests compile.
- New `Sources/UpscaleCore/Job/ChapterSkipDetector.swift`:
  ```swift
  public enum ChapterSkipDetector {
      /// Chapters whose title marks an opening, ending or preview.
      public static func skippableRanges(in media: MediaInfo) -> [SkipRange]
      static func isSkippableTitle(_ title: String) -> Bool
  }
  ```
  `isSkippableTitle` lowercases and trims, then returns true when the title:
  - matches `^(op|ed)\s*\d*$` (e.g. `OP`, `ED2`, `op 1`), or
  - contains one of the whole words `opening`, `ending`, `intro`, `outro`, `preview`
    (word boundaries, so `"Ending Theme"` matches and `"Pretending"` does not), or
  - matches `^(next episode|next time)( preview)?$`.
  Everything else (`Part A`, `Avant`, `Episode 3`, numbers) is not skippable; be
  conservative, the user can add ranges by hand. The returned ranges carry the chapter
  title as `label` and are passed through `SkipRanges.normalized`.

### 8.3 Engine passthrough path

`Anime4KEngine` gains:

```swift
/// Resamples `input` straight to `output` with Lanczos, bypassing every shader pass.
/// Same texture contract as `encode`; used for skipped frames.
public func encodePassthrough(commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) throws
```

Implementation: `MPSImageLanczosScale(device:)` created in `configure` (always, not only
when `!plan.producesTargetSize`; keep a separate `passthroughScaler` property so the
existing `lanczos` logic is untouched), then `scaler.encode(commandBuffer:sourceTexture:destinationTexture:)`.
Both textures are `bgra8Unorm` and MPS handles that directly. Keep the same size guards
`encode` has. When WP11 lands (frames arrive as YUV and go through a Metal colour
conversion), passthrough must run *after* the YUV→RGB step and *before* the RGB→YUV
step, so it stays a pure resample of RGB. Write the method so the input is "the RGB
frame texture" rather than "whatever came off the pipe".

### 8.4 Job integration

In `UpscaleJob.run`:
- Build `let skipPlan = SkipPlan(ranges: SkipRanges.normalized(settings.skipRanges, duration: media.duration), frameRate: media.video.realFrameRate)`.
- In `runPipeline`, the fill loop already knows the frame index: use `reader.framesRead`
  *before* the read as the index (first frame is 0). Call
  `engine.encodePassthrough` when `skipPlan.isSkipped(frame: index)`, otherwise
  `engine.encode`. Everything else (textures, in-flight queue, readback, writer) is
  unchanged; frame accounting stays exact.
- `UpscaleProgress` gains `public var framesPassedThrough: Int = 0` (with default in
  init). Count it and report it.

### 8.5 UI

In `JobRow`, under the settings row, a disclosure "Skip segments" that shows:
- One line per range: checkbox (enabled = included in `settings.skipRanges`), label
  (chapter title or "Manual"), `start – end` as `m:ss.s`. Ranges detected from chapters
  are listed even when unchecked so the user can toggle them; keep the detected list on
  the `QueuedJob` (`public var detectedSkipRanges: [SkipRange]`, filled in
  `applyProbe`) and the chosen ones in `settings.skipRanges`.
- "Add range…" with two text fields accepting `ss`, `m:ss`, `h:mm:ss`, each with an
  optional `.fraction`. Parsing lives in core: `public enum Timecode { static func parse(_:) -> Double?; static func format(_:) -> String }`.
- "Copy skip ranges to all queued" (manual ranges only make sense across episodes of
  the same show; the button copies whatever is checked).
- Summary text on the row while queued: "Skipping 2 segments (3:00)".
- When `JobDefaults.autoSkipChapters` (WP7) is on, detected chapter ranges start
  checked; otherwise unchecked.

`JobQueue.applyProbe` fills `detectedSkipRanges` via `ChapterSkipDetector` and, if
`defaults.autoSkipChapters`, sets `settings.skipRanges` to them.

### 8.6 Test fixtures

`TestSupport.FixtureSpec` gains `chapters: [(title: String, start: Double, end: Double)]`.
Implement by writing an ffmetadata file into the temp directory and adding
`-i chapters.txt -map_metadata 1` (adjust the input index for the audio/subtitle
inputs already present) to the `makeFixture` command. ffmetadata format:

```
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=3000
title=OP
```

**Acceptance**

- Unit tests (`SkipRangesTests.swift`): normalisation (overlap, touching, inverted,
  clamp), `SkipPlan` frame mapping at 24000/1001 including boundary frames, `Timecode`
  parse/format round trips, `ChapterSkipDetector.isSkippableTitle` table with at least
  12 titles (positive and negative).
- `ProbeTests`: recorded ffprobe JSON with two chapters decodes into `MediaInfo.chapters`.
- `EngineTests`: `encodePassthrough` output at 2x equals `MPSImageLanczosScale` of the
  source within 1/255 mean absolute difference (they share the code path; the test guards
  the texture wiring), and differs from `encode` output by more than 2/255 mean.
- `UpscaleJobTests.testSkippedSegmentIsPassedThrough`: 10 s fixture with chapters
  `OP 0–3 s`, `Part A 3–7 s`, `ED 7–10 s`. Run with `skipRanges` from the detector.
  Assert: output frame count and duration equal the source (same checks as
  `testEndToEndUpscaleKeepsAudioSubtitlesAndDuration`), `framesPassedThrough` equals
  `SkipPlan.skippedFrameCount`, and the chapters survive in the output (`ffprobe -show_chapters`).
- `swift test` green; `docs/manual-test.md` gets a "Skip segments" section.

---

## WP9 — In-process pipeline cache — **measured, not needed**

Measurement first, per the stop rule below. `UPSCALE_BENCHMARK=1 swift test --filter
testReportsRepeatedConfigureCost` on the development machine, Mode A+A HQ, 1080p→4K,
three engines in one process:

```
parse:     27 / 26 / 26 ms
configure:  9 /  3 /  2 ms
```

The second `configure` costs 3 ms, two orders of magnitude under the 300 ms threshold —
macOS's own on-disk shader cache already absorbs the repeat, and the residual start-up
cost is GLSL parsing, not pipeline compilation. The cache is therefore not built. The
benchmark stays in `EngineBenchmarkTests` so the decision can be rechecked.

<details>
<summary>Original brief</summary>


"Compiling shaders…" costs seconds per job for the HQ presets, and a batch of
episodes usually shares preset and frame size. Cache compiled pipelines across jobs
within one app session.

**Deliverables**

- `Sources/UpscaleCore/Engine/PipelineCache.swift`: a thread-safe (NSLock) LRU keyed
  by `(presetID, inputSize, targetSize)` holding the `[MTLComputePipelineState]` plus
  the resolve pipeline and the `RenderPlan`. Cap at 8 entries. Public API:
  `func pipelines(for key:, build: () throws -> Entry) rethrows -> Entry`.
- `Anime4KEngine.init` takes an optional `cache: PipelineCache?`; `configure` consults
  it before `compilePipelines`.
- `JobQueue` owns one `PipelineCache` and passes it to every `UpscaleJob` (add an init
  parameter with default `nil` so tests and the CLI keep working).
- Measure first: with `UPSCALE_BENCHMARK=1`, time `configure` for Mode A+A HQ at
  1080p→4K on a cold run and a second run in the same process. Record both numbers in
  the PR. If the second run is already under 300 ms without the cache (macOS keeps its
  own on-disk shader cache), stop and report; the WP is then "not needed" and the code
  is not merged.

**Acceptance**

- `EngineTests.testSecondConfigureHitsCache`: two engines sharing a cache, second
  `configure` with equal key performs zero `makeLibrary` calls (count via an injected
  hook or by asserting the cache's `hitCount`).
- Benchmark numbers in the PR; `swift test` green.

</details>

---

## WP10 — Pipeline overlap and hardware decode

`runPipeline` blocks on `waitUntilCompleted` for the oldest frame, then does the
readback and the pipe write on the same thread. During the write the GPU may sit
idle once the in-flight queue drains. Also AV1/HEVC sources decode on the CPU.

**Deliverables**

1. Split the pipeline into two threads with a bounded queue between them:
   - Producer (current thread): read frame, upload, encode command buffer, commit,
     push `InFlightFrame` onto a `BlockingQueue<InFlightFrame>` of capacity
     `inFlightFrameLimit`.
   - Consumer (new `Thread`): pop, `waitUntilCompleted`, check `error`, readback,
     `writer.write`, return textures to the free lists (which therefore need a lock or
     a second `BlockingQueue` of free texture pairs).
   Cancellation and errors: any error on either side is stored in a shared
   `Result` slot, the other side sees it on its next queue operation, and both stop.
   Keep the existing "close pipes once, report subprocess failure, cancelled wins"
   error handling. Frame accounting stays `reader.framesRead == writer.framesWritten`.
2. Replace `FrameTextures.readback` (which allocates a `Data` per frame) with a
   preallocated per-slot `[UInt8]` buffer reused across frames; `FrameWriter.write`
   takes `UnsafeRawBufferPointer` (keep the `Data` overload for tests).
3. `DecodeProcess.arguments` adds `-hwaccel videotoolbox` before `-i`. VideoToolbox
   decodes H.264/HEVC/ProRes; for others ffmpeg falls back to software with a warning
   on stderr, which is fine. Verify the output frames are byte-identical to the
   software decode for an H.264 fixture (they should be, both are conformant decoders);
   if not, keep hwaccel behind a `DecodeOptions.hardwareDecode` flag defaulting to true
   and document the difference.

**Acceptance**

- `UPSCALE_BENCHMARK=1` report before and after for 1080p→4K Mode A+A HQ, both fps
  numbers in the PR. Expect a measurable gain; if the gain is under 5 % report it and
  ask before merging.
- `testCancelMidJobLeavesNoOrphanFFmpegProcesses` still passes; add a variant that
  cancels while the consumer is blocked on a write (use a `FixtureSpec` with a long
  duration).
- `UPSCALE_MATRIX=1` matrix green.

---

## WP11 — `yuv420p` on the pipes, colour conversion in Metal

`bgra` costs 4 bytes/pixel on both pipes; at 4K output that is 33 MB per frame. Planar
4:2:0 is 1.5 bytes/pixel. Move the colour conversion into Metal on both ends.

**Deliverables**

- `RawFrameFormat` gains `.yuv420p` (1.5 bytes per pixel; `frameByteCount` must be
  `w*h*3/2`, `bytesPerRow` is per plane and no longer a single number — replace it
  with `planeLayout(width:height:) -> [(offset: Int, width: Int, height: Int, bytesPerRow: Int)]`).
- Decode: `-pix_fmt yuv420p`. Encode input: `-pixel_format yuv420p`, and the encode
  `-vf` drops the `scale=out_color_matrix…` stage (no RGB→YUV needed any more) but
  keeps `setsar` and `setparams`.
- New Metal kernels (source strings, same style as `ResolveKernel`):
  - `yuv420_to_rgb`: reads three `r8Unorm` textures (Y at full size, Cb/Cr at half
    size, sampled bilinearly), writes `rgba16Float` (the format the chain reads, see
    `RenderPlan`). Takes a small uniform struct `{ matrix: float3x3, offset: float3 }`
    built from `ColorProperties` (bt709 / bt470bg / smpte170m / bt2020nc, tv or pc range).
  - `rgb_to_yuv420`: replaces `ResolveKernel`; writes Y at full size and Cb/Cr at half
    size by averaging 2x2 blocks. Same uniform struct, inverse matrix.
- `FrameTextures` gains upload/readback helpers for the three planes from one
  contiguous buffer (`replace(region:…withBytes:bytesPerRow:)` per plane).
- `Anime4KEngine.encode` and `encodePassthrough` take a `FrameInput` (three planes)
  and a `FrameOutput` (three planes). The passthrough path is: YUV→RGB, Lanczos to
  target size, RGB→YUV.
- `ColorProperties` gains `func metalMatrices() -> (toRGB: simd_float3x3, toRGBOffset: SIMD3<Float>, toYUV: …, toYUVOffset: …)` with the standard coefficients. Put the
  coefficient tables in one place with a comment citing the ITU-R spec each came from.

**Acceptance**

- `ColorPropertiesTests`: converting a synthetic frame with the new kernels
  matches ffmpeg's own `scale` conversion (generate reference via
  `ffmpeg -f lavfi -i testsrc2 -pix_fmt yuv420p` then `-pix_fmt rgb24`) within
  1.5/255 mean absolute difference for bt709/tv, bt709/pc and bt470bg/tv.
- `EngineTests.testModeAFastMatchesMPVReference` still passes (it feeds PNG → the chain
  and compares to the mpv golden; adapt its upload path to the new `FrameInput` via a
  test helper that does the RGB→YUV→RGB round trip, and widen the tolerance only if the
  round trip alone explains the difference; report the new number).
- Benchmark before/after in the PR (this WP exists for throughput; report it).
- `UPSCALE_MATRIX=1` green, including the 601-tagged and full-range rows.

---

## WP12 — 10-bit SDR input and output

Most modern anime encodes are 10-bit HEVC. Accept them instead of refusing.

**Deliverables**

- `RawFrameFormat.yuv420p10le`: planes are `UInt16` little-endian, 3 bytes/pixel total.
  `r16Unorm` textures; values are 0…1023 in the low bits, so the YUV→RGB kernel gets a
  `scale` uniform (`65535/1023`) or the upload step shifts left by 6. Pick one and
  document it in the kernel comment.
- `MediaInfo.rejectionReason()` accepts `bitDepth == 10`. Still refuse 12-bit, HDR
  transfers and BT.2020 primaries (the shaders were trained on SDR; leave HDR for a
  later plan).
- `EncoderSettings` gains `public var outputBitDepth: Int` (8 or 10; default 10 when
  the source is 10-bit, else 8). `encodePixelFormat` returns `p010le` for 10-bit
  VideoToolbox HEVC with `-profile:v main10`; H.264 VideoToolbox has no 10-bit, so the
  UI hides 10-bit output for H.264 and the core throws
  `UpscaleError.unsupportedInput` if asked.
- Both pipe formats (8- and 10-bit) are chosen per job from the source depth; the
  encode-side pipe is `yuv420p10le` when output is 10-bit.
- UI: an "Output depth" segmented control (8-bit / 10-bit) next to the encoder picker.

**Acceptance**

- `testTenBitInputIsRefusedBeforeAnythingIsWritten` becomes
  `testTenBitInputIsAccepted`: a `yuv420p10le` fixture (`videoCodec: "libx265"`,
  `pixelFormat: "yuv420p10le"`) produces an output with `pix_fmt` `yuv420p10le` and
  the usual duration/frame-count checks. Keep a refusal test for 12-bit and for
  `smpte2084`.
- Matrix gains 10-bit rows across containers.
- Golden test: feed the 480p PNG as a 10-bit frame and compare to the 8-bit golden with
  the same tolerance.

---

## WP13 — Modes B, C, B+B, C+A

**Deliverables**

- Vendor from bloc97/Anime4K at the tag already pinned in `NOTICE`/`README` (v4.0.1) the
  files: `Anime4K_Restore_CNN_Soft_M`, `_Soft_S`, `_Soft_VL`,
  `Anime4K_Upscale_Denoise_CNN_x2_M`, `_x2_S`, `_x2_VL`. Copy the exact per-mode file
  orderings from that tag's `GLSL_Instructions.md` (the mpv key-binding lines) into
  `Preset.all`; do not reconstruct them from memory. Ids: `mode-b-fast`, `mode-b-hq`,
  `mode-c-fast`, `mode-c-hq`, `mode-bb-fast`, `mode-bb-hq`, `mode-ca-fast`, `mode-ca-hq`.
- `Preset` gains `public let summary: String` — one line per Anime4K's docs (A: "for
  blurry sources", B: "for sources with ringing/aliasing", C: "for clean high-quality
  sources with noise", …) shown as help text in the picker.
- Group the picker in the UI by Fast/HQ.

**Acceptance**

- `ShaderCompilationTests` covers the new files (it iterates `Preset.allShaderFiles`;
  confirm it picks them up).
- `EngineTests.testEveryPresetPlansAtTwoAndFourTimes` passes for all 12 presets.
- Golden test for Mode B (HQ) at 2x against an mpv screenshot generated with
  `Tests/UpscaleCoreTests/Fixtures/generate-golden.py` (it already takes the shader
  file list as its first argument; pass the Mode B HQ ordering). Same tolerance as
  Mode A.

---

## WP14 — Before/after preview

Let the user see what a preset does to one frame before running a 40-minute job.

**Deliverables**

- Core: `public struct FramePreview { public static func render(input: URL, at seconds: Double, settings: UpscaleJobSettings, tools:, device:, catalog:) throws -> (original: CGImage, upscaled: CGImage) }`.
  Decode one frame with ffmpeg (`-ss <t> -i <input> -frames:v 1 -f rawvideo -pix_fmt <format> pipe:1`),
  run `Anime4KEngine` once (reuse `PipelineCache` from WP9), convert both textures to
  `CGImage`. The original is Lanczos-resampled to the same target size so the two can
  be compared 1:1.
- UI: a "Preview…" button per row opening a sheet with a split view: a draggable
  divider between original (left) and upscaled (right) over the same image, a time
  slider (0…duration), and the preset/scale pickers bound to the same job settings so
  changing them re-renders. Rendering happens off the main actor; show a spinner and
  cancel any in-flight render when a newer request starts.
- Zoom: fit-to-window by default, 100 % toggle.

**Acceptance**

- `FramePreviewTests`: renders at t = 1 s from a fixture; both images have the target
  size; upscaled differs from original by more than 2/255 mean.
- Manual test section.

---

## WP15 — Software encoders and encoder options

VideoToolbox is fast but its quality ceiling on line art is low. Offer the software
encoders when the installed ffmpeg has them.

**Deliverables**

- `VideoEncoder` gains `.libx265`, `.libx264`, `.libsvtav1`. Each case knows its
  rate-control flag (`-crf` for the software ones with sensible ranges; the existing
  `-q:v` for VideoToolbox), its 10-bit pixel format (`yuv420p10le` for x265/svt-av1,
  x264 needs the 10-bit build — probe `ffmpeg -h encoder=libx264` for `yuv420p10le`),
  and its `-preset` list.
- `EncoderSettings` gains `preset: String?` (encoder speed preset) and keeps one
  `quality` knob; document the mapping per encoder in a comment table (VideoToolbox
  1…100 higher-is-better vs CRF lower-is-better: present a single 0…100 "Quality"
  slider in the UI and map it per encoder in core, with the raw value shown in a
  tooltip).
- `FFmpegTools` gains `availableEncoders: Set<String>` filled once at locate time from
  `ffmpeg -hide_banner -encoders`. `JobQueue` exposes it; the UI hides encoders that
  are missing. Selecting an unavailable encoder in core throws.
- Advanced disclosure per row: encoder preset, 8/10-bit (from WP12), and for
  VideoToolbox the `-allow_sw 1`/`-realtime 0`/`-prio_speed 0` flags as a single
  "Prefer quality over speed" toggle.

**Acceptance**

- `EncoderSettingsTests`: argument lists for each encoder at 8- and 10-bit, and the
  quality mapping at 0/50/100.
- Integration: one short job per available software encoder (skip when missing).
- Matrix gains an encoder dimension for the ones present on the machine.

---

## WP16 — Target-height scaling

2x/4x is not what people ask for; "make it 1080p / 1440p / 2160p" is.

**Deliverables**

- `UpscaleJobSettings.scale: Int` becomes `public var target: ScaleTarget` with
  `enum ScaleTarget: Equatable, Sendable { case factor(Int); case height(Int) }`.
  Keep a computed `scale` for compatibility that returns the factor, or for `.height`
  the smallest integer factor whose output is ≥ the requested height (the chain must
  upscale by an integer, the Lanczos pass then resizes down to the exact height).
  Width follows the source aspect (respecting SAR when anamorphic) and is rounded to
  even.
- `EncodePlan.make` and `Anime4KEngine.configure(inputSize:targetSize:)` already
  accept an arbitrary target size; `RenderPlan.producesTargetSize` drives the existing
  Lanczos resample. No engine change expected.
- A "Don't upscale beyond source ×4" guard: refuse `.height` targets that need a
  factor above 4 with a clear message.
- UI: Scale picker gets 1080p / 1440p / 2160p entries alongside 2x / 4x.
  `resolutionSummary` shows the real output size.

**Acceptance**

- Unit tests for the factor/height maths on 854x480, 1280x720, 1920x1080 and an
  anamorphic 720x576 SAR 64:45 source.
- Integration: 480p → 1080p output has height 1080 and even width.

---

## WP17 — Robustness and small UX

Independent items; each is its own small PR. Do them in this order.

1. **Overwrite check.** If the output exists when Start is pressed, the row shows
   "Output exists" with Overwrite / Rename (appends ` (1)`) buttons; nothing runs
   until chosen. Core: `JobQueue` state `.needsDecision(reason)`.
2. **Folder drop.** Dropping a directory adds every file inside (recursive, sorted by
   name) whose extension is in a video set (`mkv mp4 m4v mov avi ts m2ts webm wmv flv`).
   Hidden files skipped.
3. **Keep awake.** While `isRunning`, hold a `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason:)`
   token; end it when the queue drains.
4. **Notification.** Post a `UNUserNotification` when the queue finishes ("3 files
   done, 1 failed"). Request permission on first Start.
5. **Copy diagnostics.** Failed rows get "Copy Diagnostics", which puts the input's
   ffprobe JSON, the full ffmpeg argument lists, and `failureDetail` on the pasteboard.
   Core: `JobQueue.diagnostics(for id:) -> String`.
6. **Interlaced sources.** ffprobe `field_order` other than `progressive`/unknown:
   add `yadif=mode=send_frame` to the decode command before the fps normalisation and
   show "deinterlacing" in the row summary. Test with a fixture created via
   `-vf tinterlace=mode=interleave_top` and `-flags +ilme+ildct`.
7. **VFR warning.** When `averageFrameRate` and `realFrameRate` differ by more than 1 %,
   show a yellow note on the row: "Variable frame rate source; output will be constant
   <rate>". No behaviour change (decode already forces CFR).
8. **Disk space.** Before starting, estimate output size as
   `duration × (video bitrate guess from quality/encoder table + sum of copied stream
   bitrates)` and refuse with a message if free space on the output volume is below
   1.5× that. Keep the table simple and conservative.
9. **Pause/resume.** `UpscaleJob.pause()` sends `SIGSTOP` to both ffmpeg processes and
   parks the producer thread on a condition; `resume()` sends `SIGCONT` and signals it.
   Row gets a Pause/Resume button. Cancelling while paused must still work (resume
   first, then cancel).

**Acceptance per item**

- A unit or integration test for the core part (`JobQueueTests` for 1, 2, 5, 7, 8;
  `UpscaleJobTests` for 6 and 9). Items 3 and 4 are UI-only: manual test section.

---

## WP18 — Command-line target

`UpscaleCore` is already a package; add an executable so batches can be scripted and
CI can run real jobs without Xcode.

**Deliverables**

- `Package.swift`: executable target `upscale-cli` (source in `Sources/UpscaleCLI/main.swift`)
  depending on `UpscaleCore`. Argument parsing by hand (no swift-argument-parser, rule 7).
  ```
  upscale-cli INPUT [INPUT…] [--preset ID] [--scale 2|4|1080p|1440p|2160p]
              [--encoder NAME] [--quality N] [--bit-depth 8|10]
              [--skip m:ss-m:ss[,…]] [--auto-skip-chapters] [--output-dir DIR]
              [--list-presets] [--list-encoders]
  ```
- Progress on stderr as one rewriting line (`frame 1200/34500  12.3 fps  eta 43:10`);
  exit code 0/1; errors as the same one-line messages the app shows.
- Ctrl-C cancels cleanly (install a `SIGINT` handler that calls `job.cancel()`).

**Acceptance**

- `swift run upscale-cli --list-presets` prints all presets.
- A test that runs the CLI binary on a fixture via `Process` and checks the exit code
  and output file.

---

## WP19 — Bundled ffmpeg for distribution

**Deliverables**

- `Scripts/fetch-ffmpeg.sh`: downloads a static, LGPL-compatible macOS arm64 ffmpeg and
  ffprobe (pin the URL and the SHA-256 in the script), verifies the hash, and places
  them in `App/Upscale/Resources/bin/`. Document the licence obligations in `NOTICE`
  (which build, which licence, where the source is).
- Xcode: copy `bin/` into `Contents/Resources/bin` (already the first place
  `FFmpegLocator` looks; confirm the exact path it expects and match it).
- `Scripts/release.sh`: `xcodebuild archive`, codesign with hardened runtime, notarise
  (`notarytool`), staple, zip. Read the signing identity and Apple ID from
  environment variables; never commit them.
- `README.md`: "Homebrew ffmpeg required" becomes "bundled; Homebrew used if present
  and newer".

**Acceptance**

- `FFmpegLocatorTests` gains a case where a fake bundle path is found before Homebrew.
- A fresh macOS user account without Homebrew can run the built app end to end
  (manual test section).

---

## WP20 — Cross-episode audio matching (deferred; do not implement yet)

Recorded here so the design is not lost. Build only when asked.

Idea: the OP/ED audio is identical across episodes of a season. With two or more
files queued, find the longest audio segment (≥ 45 s) shared between them and propose
it as a skip range on every file.

Sketch:
- `ffmpeg -i in -vn -ac 1 -ar 8000 -f s16le pipe:1` → mono PCM.
- Frame it into 100 ms windows, 32-bin log-spaced spectrum per window (vDSP FFT),
  reduce to a 32-bit hash per window (bit = bin energy above the mean).
- For two files, slide one hash sequence over the other and count matching windows
  with Hamming distance ≤ 4; the longest run above the length threshold is the shared
  segment. Search both the first 5 minutes (OP) and last 5 minutes (ED) only.
- Confidence shown in the UI; the user confirms before it is applied.
- Tests with synthetic audio: two files that share a 90 s sine-sweep block at different
  offsets, plus noise elsewhere.
