import SwiftUI
import UpscaleCore

/// Before/after on one frame, under a draggable wipe divider.
///
/// A window rather than a sheet: it is something the user compares against the rest of
/// the queue, so it has to resize, zoom, go full screen and close like any other window.
/// The preset and scale pickers write straight back to the job, so what the user
/// settles on here is what the job runs with.
struct PreviewWindow: View {
    /// The scene id `openWindow` addresses.
    static let sceneID = "preview"

    @EnvironmentObject private var queue: JobQueue
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID

    @State private var images: FramePreview.Result?
    @State private var seconds: Double = 0
    @State private var divider: Double = 0.5
    /// nil means "fit to window"; otherwise the factor the frame is drawn at.
    @State private var zoom: Double?
    /// The factor "fit" currently works out to, so zooming in starts from what is on
    /// screen rather than jumping to 100%.
    @State private var fittedZoom: Double = 1
    @State private var isRendering = false
    @State private var failure: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var hasOpened = false

    private var job: QueuedJob? { queue.jobs.first { $0.id == jobID } }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            Divider()
            controls
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(job?.displayName ?? "Preview")
        .onAppear {
            guard !hasOpened else { return }
            hasOpened = true
            seconds = min(30, (job?.media?.duration ?? 0) / 3)
            render()
        }
        .onDisappear { renderTask?.cancel() }
        // Nothing to preview any more: the row was removed, or it is already running
        // and its settings can no longer change.
        .onChange(of: job?.state) { state in
            if state == nil || state == .running || state?.isTerminal == true {
                dismiss()
            }
        }
        .onExitCommand { dismiss() }
        .focusedSceneValue(\.previewZoom, ZoomCommands(
            zoomIn: { setZoom(effectiveZoom * 1.25) },
            zoomOut: { setZoom(effectiveZoom / 1.25) },
            actualSize: { setZoom(1) },
            fit: { zoom = nil }
        ))
    }

    // MARK: - Image

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let images {
                GeometryReader { geometry in
                    let size = displaySize(for: images, in: geometry.size)
                    let frame = wipe(images: images, size: size)
                    if zoom == nil {
                        frame.frame(
                            width: geometry.size.width, height: geometry.size.height,
                            alignment: .center
                        )
                    } else {
                        // Zoomed in, the frame is larger than the window, so it scrolls.
                        ScrollView([.horizontal, .vertical]) { frame }
                    }
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in setZoom(fittedZoom * value) }
                )
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

    /// The two images stacked, with the upscaled one masked to the right of the divider.
    private func wipe(images: FramePreview.Result, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: images.original, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
            Image(decorative: images.upscaled, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
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
    }

    private func displaySize(for images: FramePreview.Result, in available: CGSize) -> CGSize {
        let width = CGFloat(images.upscaled.width)
        let height = CGFloat(images.upscaled.height)
        guard width > 0, height > 0 else { return .zero }
        let fit = min(available.width / width, available.height / height)
        let factor = zoom ?? fit
        // Recording what is on screen keeps "zoom in" continuous with "fit": without it,
        // the first click would jump to 125% from whatever the window was showing.
        if abs(fittedZoom - factor) > 0.0001 {
            DispatchQueue.main.async { fittedZoom = factor }
        }
        return CGSize(width: width * factor, height: height * factor)
    }

    private var effectiveZoom: Double { zoom ?? fittedZoom }

    private func setZoom(_ value: Double) {
        zoom = min(8, max(0.05, value))
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
                    .labelsHidden()
                    .frame(width: 165)
                    .help(job.settings.preset.summary)

                    Picker("Scale", selection: scaleBinding(job)) {
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }

                zoomControls

                Spacer(minLength: 8)
                Text("Original ◀ | ▶ Upscaled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            // The keyboard shortcuts live on the View menu instead, so they are not
            // bound twice.
            Button {
                setZoom(effectiveZoom / 1.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out (⌘−)")

            Text(String(format: "%.0f%%", effectiveZoom * 100))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 46)

            Button {
                setZoom(effectiveZoom * 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in (⌘+)")

            Button("Fit") { zoom = nil }
                .disabled(zoom == nil)
                .help("Fit to window (⌘0)")
            Button("100%") { setZoom(1) }
                .help("Actual size (⌘1)")
        }
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

/// The zoom actions the View menu drives, published by whichever preview has focus.
struct ZoomCommands: Equatable {
    let id = UUID()
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let fit: () -> Void

    static func == (lhs: ZoomCommands, rhs: ZoomCommands) -> Bool { lhs.id == rhs.id }
}

struct PreviewZoomKey: FocusedValueKey {
    typealias Value = ZoomCommands
}

extension FocusedValues {
    var previewZoom: ZoomCommands? {
        get { self[PreviewZoomKey.self] }
        set { self[PreviewZoomKey.self] = newValue }
    }
}
