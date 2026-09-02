# Upscale

An offline Anime4K video upscaler for macOS. It reads any container ffmpeg can demux
(including Matroska), runs an Anime4K shader preset on the GPU through Metal, and
writes an upscaled file with the original audio, subtitles and attachments carried
through.

This is a batch tool, not a player: quality presets that would stutter during playback
are fine here.

## Requirements

- macOS 13 or later.
- Xcode 15 or later to build.
- ffmpeg and ffprobe on the machine — `brew install ffmpeg`. The app looks in its own
  bundle first, then `/opt/homebrew/bin` and `/usr/local/bin`, then `PATH`.

## Layout

| Path | What it is |
| --- | --- |
| `Package.swift` | The `UpscaleCore` library and its tests. All logic lives here. |
| `Sources/UpscaleCore/` | ffmpeg process wrappers, the GLSL→MSL converter, the Metal chain, the job pipeline. |
| `Sources/UpscaleCore/Resources/Shaders/` | Anime4K `.glsl` files, vendored from release v4.0.1. |
| `App/Upscale.xcodeproj` | The SwiftUI app target; depends on the package. |
| `docs/manual-test.md` | The manual script for the parts tests cannot reach. |

## Building and testing

```sh
swift test                                    # the core library
xcodebuild -project App/Upscale.xcodeproj -scheme Upscale build
```

Two suites are opt-in because they are slow:

```sh
UPSCALE_BENCHMARK=1 swift test --filter EngineBenchmarkTests   # throughput report
UPSCALE_MATRIX=1 swift test --filter MatrixTests               # container/codec matrix
```

`MatrixTests` runs every combination of container, source codec, frame rate, aspect
ratio and stream layout end to end, checking geometry, colour tags, stream survival,
duration and A/V drift on each output. `docs/manual-test.md` covers the UI.

## How it works

```
input.mkv → ffmpeg (decode to raw bgra) → Metal: Anime4K passes → ffmpeg (encode + mux) → output.mkv
```

Two ffmpeg subprocesses are connected to the app by pipes; the app never links libav*.
Frames cross as raw `bgra`, which maps 1:1 onto `MTLPixelFormat.bgra8Unorm`.

The Anime4K shaders are mpv user shaders written in GLSL. They are translated to Metal
Shading Language at runtime and compiled with `MTLDevice.makeLibrary(source:)`, so no
Metal toolchain is needed at build time. The translation and the render graph follow
mpv's semantics closely enough that Mode A output matches an mpv screenshot to a mean
absolute difference of about 0.01/255 — see `Anime4KEngineTests`.

## Scope of v1

- Presets: Anime4K Mode A and Mode A+A, each in a Fast and an HQ variant.
- Encoders: `hevc_videotoolbox` (default) and `h264_videotoolbox`.
- 8-bit SDR input only. 10-bit and HDR sources are refused with a clear message rather
  than silently producing wrong colours.
- Preset, scale, encoder, quality and an optional output folder are remembered between
  launches, and one row's settings can be pushed onto every other queued row.

## Licences

Upscale bundles third-party shaders and ports third-party code. See `NOTICE`.
