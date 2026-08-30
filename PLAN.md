# Upscale — Offline Anime4K Video Upscaler for macOS

Overseer plan. Each work package (WP) below is a self-contained brief for an implementation model.
Read the **Architecture** and **Global rules** sections before starting any WP.

## Goal

A macOS SwiftUI app that takes a video file (including Matroska/MKV), applies an Anime4K
shader preset (e.g. Mode A, Mode A+A) on the GPU via Metal, and writes an upscaled output
file. Offline/batch — not real-time playback — so quality presets that stutter in a player
are fine here.

## Why this shape

- **AVFoundation cannot demux MKV**, so FFmpeg handles container/codec work.
- **mpv cannot apply `--glsl-shaders` in its encoding mode** (shaders live in the render
  path only), so a player-based shortcut is off the table.
- The Homebrew ffmpeg on this machine (9.0.1) is **not** built with `libplacebo`/Vulkan,
  so the `-vf libplacebo=custom_shader_path=...` route would require a custom ffmpeg build
  and MoltenVK. Documented as a fallback (Appendix B), not the main path.
- [Anime4KMetal](https://github.com/imxieyi/Anime4KMetal) (Apache-2.0) already contains a
  runtime GLSL→MSL converter for mpv-style hook shaders, based on mpv's own parser. We
  vendor/port that converter instead of writing one from scratch.
- Metal is chosen over Vulkan: native on macOS, no MoltenVK translation layer, and the
  reference converter already targets Metal.

## Architecture

```
input.mkv
   │
   ▼
[ffmpeg #1: decode]  -i input.mkv -map 0:v:0 -f rawvideo -pix_fmt <fmt> pipe:1
   │  raw frames over stdout pipe
   ▼
[Swift: FrameReader]  fixed-size reads → CVPixelBuffer/MTLTexture upload
   │
   ▼
[Metal: Anime4K chain]  ordered .glsl hook passes compiled to MSL at runtime
   │  texture pool, unified memory (storageModeShared) on Apple Silicon
   ▼
[Swift: FrameWriter]  readback → raw frames over stdin pipe
   │
   ▼
[ffmpeg #2: encode+mux]
   -f rawvideo -pix_fmt <fmt> -s WxH -r <fps> -i pipe:0   (processed video)
   -i input.mkv                                            (original, for other streams)
   -map 0:v -map 1:a? -map 1:s? -map 1:t? -c:a copy -c:s copy
   -c:v <encoder> ... output.mkv
```

- Two ffmpeg subprocesses connected to the app by pipes. The app never links libav*;
  C-interop with FFmpeg libraries is explicitly out of scope for v1 (much harder for
  marginal gain).
- ffmpeg discovery: use bundled binary if present in app bundle, else `/opt/homebrew/bin`,
  else PATH. Abstract behind one resolver function.
- Pixel format between ffmpeg and Metal: start with `bgra` (8-bit) for simplicity —
  matches `MTLPixelFormat.bgra8Unorm`, no manual YUV plane handling. 1080p bgra ≈ 8 MB per
  frame in, 4K ≈ 33 MB out; pipes on Apple Silicon sustain this easily for offline use.
  If profiling shows the pipe is the bottleneck, switch input side to `yuv420p` and do the
  YUV→RGB conversion in a Metal pass (that is what Anime4KMetal does).
- HDR / 10-bit / dolby-vision inputs: out of scope for v1. Detect via ffprobe and refuse
  with a clear error rather than producing wrong colors.

## Global rules for implementation models

1. Swift 5.9+, SwiftUI, macOS 13+ target. Xcode project, no external Swift package
   dependencies unless a WP says so.
2. App Sandbox **disabled** (the app spawns ffmpeg and reads/writes arbitrary paths;
   not App Store distribution). If this changes, revisit in WP1.
3. Keep the Apache-2.0 license headers on any code taken from Anime4KMetal, and add a
   NOTICE file crediting Anime4KMetal and bloc97/Anime4K.
4. Every WP ends with its acceptance checks passing. Do not start the next WP on top of
   failing checks.
5. No silent fallbacks: if ffmpeg exits non-zero, if a shader fails to compile, or if a
   frame count mismatches, surface the error with the shortest decisive ffmpeg/Metal
   message attached.
6. Long-running work off the main thread; UI updates via `@MainActor`.

## Work packages

### WP1 — Scaffold and ffmpeg wrapper
**Deliverables**
- Xcode SwiftUI app target `Upscale`, plus a unit-test target.
- `FFmpegLocator`: resolves ffmpeg/ffprobe path (bundle → /opt/homebrew/bin → PATH).
- `Probe`: runs `ffprobe -v error -print_format json -show_streams -show_format`,
  decodes into a `MediaInfo` struct (video codec, width, height, fps as rational,
  pix_fmt, bit depth, duration, frame count estimate, audio/subtitle stream list).
- `DecodeProcess` / `EncodeProcess`: `Process` wrappers exposing `FileHandle` pipes,
  termination status, and captured stderr (ring buffer, last ~200 lines).
- Progress: parse `-progress pipe:2` (or stderr `frame=` lines) from the encode process.

**Acceptance**
- Unit test: probe a small MKV fixture, assert stream fields.
- Integration test: decode fixture → pipe raw frames straight back into encode process
  (no processing) → output MKV plays, duration matches source ±1 frame, audio and
  subtitles present (`ffprobe` the output in the test).

### WP2 — Shader vendoring + GLSL→MSL converter
**Deliverables**
- Vendor the needed `.glsl` files from bloc97/Anime4K (pin a release tag) into
  `Resources/Shaders/`.
- `Preset` model: named ordered lists of shader files. v1 ships exactly:
  - Mode A (Fast + HQ) and Mode A+A (Fast + HQ). Copy the exact file orderings from the
    Anime4K `GLSL_Instructions` docs / Anime4KMetal presets. Vendor only the `.glsl`
    files these four presets need. Other modes are v2.
- Port the converter from Anime4KMetal: parse mpv hook directives
  (`//!HOOK`, `//!BIND`, `//!SAVE`, `//!WIDTH`, `//!HEIGHT`, `//!WHEN`, `//!DESC`,
  `//!COMPONENTS`) and translate GLSL bodies to MSL, compiled at runtime with
  `MTLDevice.makeLibrary(source:)`.
- Port, do not reinvent: keep the vendored converter's semantics (HOOK point graph,
  LUMA derivation, texture sizing rules) even where they look odd — they mirror mpv.

**Acceptance**
- XCTest: every shipped `.glsl` file converts and compiles to a `MTLLibrary` without
  error on the host GPU (mirrors Anime4KMetal's own test suite approach).
- XCTest: directive parser round-trips a hand-written fixture shader with all
  directive types.

### WP3 — Metal render chain
**Deliverables**
- `Anime4KEngine`: given a preset and input texture size, builds the pass graph
  (respecting `//!WHEN` size conditions, `//!SAVE` intermediate textures, LUMA binds),
  allocates a reusable texture pool, and runs the chain per frame on a
  `MTLCommandQueue`.
- Input: `bgra8Unorm` texture. Output: `bgra8Unorm` texture at target scale
  (2× default). Final resample to exact target size with a bilinear/`MPSImageLanczosScale`
  pass when the chain's natural output size differs.
- Throughput: process frame N+1's upload while N is on the GPU (double-buffer,
  `storageModeShared`, no per-frame allocations after warmup).

**Acceptance**
- Golden test: run Mode A on a bundled 480p PNG, compare output against a reference
  PNG generated once with mpv (`mpv --glsl-shaders=... screenshot`) — allow small
  per-pixel tolerance (e.g. mean abs diff < 2/255).
- Benchmark test (not CI-gating): report fps for 1080p→4K Mode A+A HQ on this machine;
  expectation on M1 Pro is a usable offline rate (single-digit to tens of fps is fine).

### WP4 — Pipeline orchestration
**Deliverables**
- `UpscaleJob`: wires WP1 decode → WP3 engine → WP1 encode. Backpressure: bounded
  frame queue (e.g. 4 in flight) so memory stays flat. Cancellation tears down both
  processes and the queue cleanly.
- Frame accounting: frames read == frames written, else fail the job.
- Encoder settings v1: VideoToolbox hardware encoders — `hevc_videotoolbox` (default)
  and `h264_videotoolbox`, both with a quality knob; `-tag:v hvc1` for QuickTime compat
  when HEVC output is .mp4/.mov; audio +
  subtitles + attachments stream-copied for .mkv output; output container defaults to
  input container.
- Odd-dimension guard (2× of odd sizes), fps as exact rational (`-r 24000/1001` style,
  taken from probe, never floated).

**Acceptance**
- End-to-end CLI-level test (XCTest invoking the job directly): 5-second 1080p MKV with
  audio + SRT subs → 4K MKV; checks: plays in mpv, duration matches, audio/subs intact,
  output height == 2× input.
- Cancel mid-job leaves no orphan ffmpeg processes (assert via `pgrep` in test).

### WP5 — SwiftUI app
**Deliverables**
- Single-window app: drag-and-drop or file picker (accept any file; probe decides),
  queue list of jobs, per-job: preset picker, scale (2×/4× where sensible), encoder +
  quality, output destination.
- Progress: frames done / total, current fps, ETA, per-job state
  (queued/running/done/failed/cancelled), error text on failure (short ffmpeg/Metal
  message, expandable detail).
- Jobs run sequentially by default.
- Keep the view layer thin: all logic in the WP4 job/queue types; UI observes.

**Acceptance**
- Manual script in `docs/manual-test.md`: drop MKV, pick A+A HQ, watch progress,
  cancel one job, complete another, verify output.

### WP6 — Hardening and verification pass
- Run /code-review level high over the whole codebase; fix findings.
- Test matrix: mkv/mp4 inputs; h264/hevc/av1 sources (av1 decode is CPU via ffmpeg —
  fine); 23.976/25/60 fps; anamorphic SAR ≠ 1 (scale respecting SAR or refuse);
  no-audio input; multi-audio input; 10-bit input refused with clear message.
- Duration/AV-sync check on every matrix output via ffprobe diff script.

## Risks (ranked)

1. **Converter port (WP2) is the hard part.** Mitigation: vendor Anime4KMetal code as
   directly as licensing allows; lean on its test suite pattern; golden-frame test
   against mpv output catches semantic drift.
2. **Color/range subtleties** (limited vs full range, BT.601 vs 709 flags through
   rawvideo pipes drop metadata). Mitigation: explicitly pass `-color_range`,
   `-colorspace`, `-color_primaries`, `-color_trc` from probe into the encode command;
   matrix test includes a 601-flagged file.
3. **Pipe throughput at 4K output.** Mitigation: bgra now, yuv420p+Metal-CSC later if
   profiling demands; double-buffering in WP3.
4. **A/V sync drift from fps mishandling.** Mitigation: rational fps end-to-end,
   frame-count assertion in WP4.

## Decisions (confirmed by user, 2026-08-30)

- Encoders: VideoToolbox hardware only for v1 — `hevc_videotoolbox` default,
  `h264_videotoolbox` selectable. Software encoders deferred.
- Presets: Mode A and Mode A+A (Fast + HQ variants) only in v1.
- ffmpeg: Homebrew install required for v1; bundling deferred to distribution time.

## Appendix A — References

- Anime4K shaders + mode docs: https://github.com/bloc97/Anime4K
- GLSL→Metal converter reference: https://github.com/imxieyi/Anime4KMetal (Apache-2.0)
- mpv hook directive semantics: mpv source, `video/out/gpu/user_shaders.c` and docs.

## Appendix B — Fallback route (not chosen)

Build ffmpeg with libplacebo + Vulkan/MoltenVK (`homebrew-ffmpeg` tap or manual build),
then one command does everything:
`ffmpeg -init_hw_device vulkan -i in.mkv -vf libplacebo=custom_shader_path=A4K_chain.glsl ...`
with the preset's `.glsl` files concatenated into one. Pros: no Swift GPU code at all,
app becomes a thin GUI. Cons: custom ffmpeg build to maintain, MoltenVK layer, harder to
ship. Revisit only if the WP2/WP3 converter port stalls.
