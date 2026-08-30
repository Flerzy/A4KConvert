# Manual test script

The queue UI is the one part of Upscale that automated tests do not cover end to end.
Work through this list after any change to `App/Upscale/` or to `JobQueue`.

## Prerequisites

- `brew install ffmpeg` (v1 requires a Homebrew install; the app looks in the bundle,
  then `/opt/homebrew/bin` and `/usr/local/bin`, then `PATH`).
- A test file with several streams. To make one:

  ```sh
  ffmpeg -f lavfi -i testsrc2=size=854x480:rate=24000/1001 \
         -f lavfi -i sine=frequency=440:sample_rate=48000 \
         -map 0:v -map 1:a -t 30 \
         -c:v libx264 -pix_fmt yuv420p -c:a aac -metadata:s:a:0 language=eng \
         sample.mkv
  ```

- Build and run:

  ```sh
  xcodebuild -project App/Upscale.xcodeproj -scheme Upscale -configuration Debug build
  open ~/Library/Developer/Xcode/DerivedData/Upscale-*/Build/Products/Debug/Upscale.app
  ```

## 1. Adding files

1. Launch the app. The window shows "Drop video files here" and no error banner.
   - If a red banner reports ffmpeg is missing, stop: fix the install first.
2. Drag `sample.mkv` onto the window. A blue border appears while dragging.
3. The row appears, briefly shows **Reading**, then **Queued** with
   `854x480 → 1708x960` and the duration.
4. Press ⌘O and add the same file again. A second row appears.
5. Remove the second row with its **Remove** button.

## 2. Settings

On a queued row:

1. Set **Preset** to `Mode A+A (HQ)`.
2. Set **Scale** to `4x`. The summary updates to `854x480 → 3416x1920`.
3. Set **Encoder** to `H.264 (VideoToolbox)`, then back to HEVC.
4. Drag **Quality** and confirm the number above the slider tracks it.
5. Click **Output…**, pick a destination, and confirm hovering the button shows the
   new path in its tooltip.
6. Set **Scale** back to `2x`.

## 3. Running and cancelling

1. Click **Start**. The row goes to **Running**.
2. It shows "Compiling shaders…" first — the HQ presets take a few seconds here on a
   cold shader cache — then a progress bar with
   `N / M frames · X fps · MM:SS left`.
3. Click **Cancel** while it runs. The row becomes **Cancelled** within a second or two.
4. Check no ffmpeg survived the cancel:

   ```sh
   pgrep -fl ffmpeg
   ```

   It must print nothing.
5. Click **Retry**, then **Start**, and let this one finish. The row becomes **Done**.
6. Click **Show in Finder** and confirm the output file is selected.

## 4. Verifying the output

```sh
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height -of csv out.mkv
ffprobe -v error -show_entries format=duration -of csv out.mkv
mpv out.mkv
```

- Video is `hevc` at exactly twice the source width and height.
- The audio stream is still `aac` and its language tag survived.
- Duration matches the source to within one frame.
- Audio stays in sync to the end of playback.

## 5. Error surfacing

1. Add a 10-bit file:

   ```sh
   ffmpeg -f lavfi -i testsrc2=size=320x240:rate=25 -t 5 \
          -c:v libx265 -pix_fmt yuv420p10le tenbit.mkv
   ```

   The row goes straight to **Failed** with "10-bit video … is not supported in v1",
   without any file being written.
2. Add a queued job whose output path is not writable (choose `/` as the destination).
   Start it. The row fails with the ffmpeg message on one line, and a **Details**
   link expands the full stderr tail.
3. Add a non-video file (a `.txt`). It fails with "No video stream found in …".

## 6. Queue behaviour

1. Add three files and press **Start**.
2. Only one runs at a time; the others stay **Queued**.
3. **Cancel All** stops the running job and marks the rest **Cancelled**.
4. **Clear Finished** removes every terminal row and leaves nothing else.
