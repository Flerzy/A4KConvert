import SwiftUI
import UpscaleCore

/// Before/after on one frame, under a draggable wipe divider.
///
/// The preset and scale pickers write straight back to the job, so what the user
/// settles on here is what the job runs with.
struct PreviewSheet: View {
    @EnvironmentObject private var queue: JobQueue
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID

    @State private var images: FramePreview.Result?
    @State private var seconds: Double = 0
    @State private var divider: Double = 0.5
    @State private var isFitToWindow = true
    @State private var isRendering = false
    @State private var failure: String?
    @State private var renderTask: Task<Void, Never>?

    private var job: QueuedJob? { queue.jobs.first { $0.id == jobID } }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            Divider()
            controls
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            seconds = min(30, (job?.media?.duration ?? 0) / 3)
            render()
        }
        .onDisappear { renderTask?.cancel() }
    }

    // MARK: - Image

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let images {
                GeometryReader { geometry in
                    let size = displaySize(for: images, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: images.original, scale: 1)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                        Image(decorative: images.upscaled, scale: 1)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                            // The wipe: the upscaled side is drawn only to the right of
                            // the divider, over the same pixels.
                            .mask(alignment: .topLeading) {
                                Rectangle()
                                    .frame(width: size.width * (1 - divider))
                                    .offset(x: size.width * divider)
                            }
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: size.height)
                            .offset(x: size.width * divider - 1)
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                divider = min(1, max(0, value.location.x / size.width))
                            }
                    )
                    .frame(
                        width: geometry.size.width, height: geometry.size.height,
                        alignment: .center
                    )
                }
                .modifier(ScrollWhenZoomed(isFitToWindow: isFitToWindow))
            } else if failure == nil {
                ProgressView("Rendering…")
            }

            if let failure {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    Text(failure).textSelection(.enabled)
                }
                .padding()
            }

            if isRendering, images != nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }
        }
    }

    private func displaySize(for images: FramePreview.Result, in available: CGSize) -> CGSize {
        let width = CGFloat(images.upscaled.width)
        let height = CGFloat(images.upscaled.height)
        guard isFitToWindow, width > 0, height > 0 else { return CGSize(width: width, height: height) }
        let scale = min(available.width / width, available.height / height, 1)
        return CGSize(width: width * scale, height: height * scale)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(Timecode.format(seconds))
                    .monospacedDigit()
                    .frame(width: 62, alignment: .leading)
                Slider(value: $seconds, in: 0...max(1, job?.media?.duration ?? 1)) { editing in
                    if !editing { render() }
                }
            }

            HStack(spacing: 12) {
                if let job {
                    Picker("Preset", selection: presetBinding(job)) {
                        ForEach(Preset.Tier.allCases, id: \.self) { tier in
                            Section(tier.displayName) {
                                ForEach(Preset.presets(tier: tier)) { preset in
                                    Text(preset.name).tag(preset)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 200)
                    .help(job.settings.preset.summary)

                    Picker("Scale", selection: scaleBinding(job)) {
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    }
                    .frame(maxWidth: 110)
                }

                Toggle("Fit to window", isOn: $isFitToWindow)
                Spacer()
                Text("Original ◀ | ▶ Upscaled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    private func presetBinding(_ job: QueuedJob) -> Binding<Preset> {
        Binding(
            get: { job.settings.preset },
            set: { value in
                queue.update(job.id) { $0.preset = value }
                render()
            }
        )
    }

    private func scaleBinding(_ job: QueuedJob) -> Binding<Int> {
        Binding(
            get: { job.settings.scale },
            set: { value in
                queue.update(job.id) { $0.scale = value }
                render()
            }
        )
    }

    // MARK: - Rendering

    /// Renders the current frame, superseding whatever request was in flight.
    private func render() {
        renderTask?.cancel()
        isRendering = true
        let requested = seconds
        renderTask = Task {
            do {
                let result = try await queue.renderPreview(for: jobID, at: requested)
                guard !Task.isCancelled else { return }
                images = result
                seconds = result.seconds
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                failure = JobQueue.message(for: error)
            }
            isRendering = false
        }
    }
}

/// At 100% the frame is larger than the sheet, so it gets scroll bars; fitted, it must
/// not, or the image jumps around inside them.
private struct ScrollWhenZoomed: ViewModifier {
    let isFitToWindow: Bool

    func body(content: Content) -> some View {
        if isFitToWindow {
            content
        } else {
            ScrollView([.horizontal, .vertical]) { content }
        }
    }
}
