import SwiftUI
import UpscaleCore

/// One queue entry: its settings while it waits, its progress while it runs, and its
/// error once it fails.
struct JobRow: View {
    @EnvironmentObject private var queue: JobQueue
    let job: QueuedJob
    @State private var showsFailureDetail = false
    @State private var showsPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if job.state == .queued || job.state == .probing {
                settings
                SkipSegmentsSection(job: job)
            }
            if job.state == .running, let progress = job.progress {
                ProgressSection(progress: progress)
            }
            if let message = job.failureMessage {
                failure(message)
            }
        }
        .sheet(isPresented: $showsPreview) {
            PreviewSheet(jobID: job.id)
                .environmentObject(queue)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    StateBadge(state: job.state)
                    if let summary = job.resolutionSummary {
                        Text(summary)
                    }
                    if let media = job.media, let duration = media.duration {
                        Text(JobRow.durationText(duration))
                    }
                    if let skips = job.skipSummary {
                        Text(skips)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .running:
            Button("Cancel") { queue.cancel(job.id) }
        case .queued, .probing:
            Button("Remove") { queue.remove(job.id) }
        case .finished:
            Button("Show in Finder") { queue.revealInFinder(job) }
        case .failed, .cancelled:
            HStack {
                Button("Retry") { queue.retry(job.id) }
                Button("Remove") { queue.remove(job.id) }
            }
        }
    }

    // MARK: - Settings

    /// Every control gets its caption above it and its own fixed width, so the row
    /// keeps one baseline and nothing truncates. Inline picker labels do neither: a
    /// segmented picker lays its label out on a line of its own.
    private var settings: some View {
        HStack(alignment: .bottom, spacing: 12) {
            labelled("Preset") {
                Picker("Preset", selection: presetBinding) {
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
            }

            labelled("Scale") {
                Picker("Scale", selection: scaleBinding) {
                    Text("2x").tag(2)
                    Text("4x").tag(4)
                }
                .labelsHidden()
                .frame(width: 70)
            }

            labelled("Encoder") {
                Picker("Encoder", selection: encoderBinding) {
                    ForEach(VideoEncoder.allCases, id: \.self) { encoder in
                        Text(encoder.shortName).tag(encoder)
                    }
                }
                .labelsHidden()
                .frame(width: 95)
                .help(job.settings.encoder.encoder.displayName)
            }

            if job.settings.encoder.encoder.supportsTenBit {
                labelled("Depth") {
                    Picker("Depth", selection: depthBinding) {
                        Text("8-bit").tag(8)
                        Text("10-bit").tag(10)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 116)
                }
                .help("Bits per sample in the written file. HEVC only.")
            }

            labelled("Quality \(job.settings.encoder.quality)") {
                Slider(value: qualityBinding, in: 20...95, step: 5)
                    .frame(width: 130)
            }

            Spacer(minLength: 8)

            Button("Output…") { queue.presentSavePanel(for: job) }
                .help(job.settings.output.path)

            Button("Preview…") { showsPreview = true }
                .disabled(job.media == nil)
                .help("See this preset on one frame before running the job")

            Menu {
                Button("Apply These Settings to All Queued") {
                    queue.applyToAllQueued(from: job.id)
                }
                Button("Use These Settings as Default") {
                    queue.makeDefaults(from: job.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
            .help("Apply these settings elsewhere")
        }
        .disabled(job.state == .probing)
        .controlSize(.small)
    }

    private func labelled<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var presetBinding: Binding<Preset> {
        Binding(
            get: { job.settings.preset },
            set: { value in queue.update(job.id) { $0.preset = value } }
        )
    }

    /// Changing the scale also moves the default output name (`…2x.mkv` → `…4x.mkv`),
    /// but only while the user has not chosen a destination of their own.
    private var scaleBinding: Binding<Int> {
        Binding(
            get: { job.settings.scale },
            set: { value in
                queue.update(job.id) { settings in
                    let wasDefault = settings.output
                        == UpscaleJobSettings.defaultOutputURL(for: job.input, scale: settings.scale)
                    settings.scale = value
                    if wasDefault {
                        settings.output = UpscaleJobSettings.defaultOutputURL(
                            for: job.input, scale: value
                        )
                    }
                }
            }
        )
    }

    /// Switching to an encoder without a 10-bit path also drops the depth, so the job
    /// can never be started in a combination the core refuses.
    private var encoderBinding: Binding<VideoEncoder> {
        Binding(
            get: { job.settings.encoder.encoder },
            set: { value in
                queue.update(job.id) { settings in
                    settings.encoder.encoder = value
                    if !value.supportsTenBit { settings.encoder.outputBitDepth = 8 }
                }
            }
        )
    }

    private var depthBinding: Binding<Int> {
        Binding(
            get: { job.settings.encoder.outputBitDepth },
            set: { value in queue.update(job.id) { $0.encoder.outputBitDepth = value } }
        )
    }

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { Double(job.settings.encoder.quality) },
            set: { value in
                queue.update(job.id) { $0.encoder = EncoderSettings(
                    encoder: $0.encoder.encoder, quality: Int(value)
                ) }
            }
        )
    }

    // MARK: - Failure

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .textSelection(.enabled)
                if job.failureDetail != nil {
                    Button(showsFailureDetail ? "Hide details" : "Details") {
                        showsFailureDetail.toggle()
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.callout)

            if showsFailureDetail, let detail = job.failureDetail {
                ScrollView {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (minutes, secs) = total.quotientAndRemainder(dividingBy: 60)
        let (hours, mins) = minutes.quotientAndRemainder(dividingBy: 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, mins, secs)
            : String(format: "%d:%02d", mins, secs)
    }
}

/// The skip-segment list: chapter-detected ranges to tick, plus ranges typed by hand.
private struct SkipSegmentsSection: View {
    @EnvironmentObject private var queue: JobQueue
    let job: QueuedJob
    @State private var isExpanded = false
    @State private var startText = ""
    @State private var endText = ""
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A plain DisclosureGroup draws no visible chevron at this control size, so
            // the section looked like dead text; this header is unmistakably a control.
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption2)
                    Text(job.skipSummary ?? "Skip segments")
                        .font(.caption)
                    if let count = detectedCount {
                        Text("(\(count) detected)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Time ranges that are resampled instead of run through Anime4K")

            if isExpanded {
                ranges
            }
        }
        .disabled(job.state == .probing)
        .controlSize(.small)
    }

    private var detectedCount: Int? {
        job.detectedSkipRanges.isEmpty ? nil : job.detectedSkipRanges.count
    }

    private var ranges: some View {
        VStack(alignment: .leading, spacing: 4) {
            if job.allSkipRanges.isEmpty {
                Text("No chapters looked like an opening or ending. Add a range below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(job.allSkipRanges, id: \.self) { range in
                HStack(spacing: 6) {
                    Toggle(isOn: binding(for: range)) {
                        Text(range.label ?? "Manual")
                            .frame(width: 140, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text("\(Timecode.format(range.start)) – \(Timecode.format(range.end))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                TextField("0:00", text: $startText).frame(width: 70)
                Text("–")
                TextField("1:30", text: $endText).frame(width: 70)
                Button("Add Range") { addRange() }
                Button("Copy to All Queued") { queue.copySkipRangesToAllQueued(from: job.id) }
                    .disabled(job.settings.skipRanges.isEmpty)
            }
            if let addError {
                Text(addError).foregroundStyle(.red)
            }
        }
        .padding(.top, 4)
        .padding(.leading, 14)
        .font(.caption)
    }

    private func binding(for range: SkipRange) -> Binding<Bool> {
        Binding(
            get: { job.isSkipRangeEnabled(range) },
            set: { queue.setSkipRange(range, enabled: $0, for: job.id) }
        )
    }

    private func addRange() {
        guard let start = Timecode.parse(startText), let end = Timecode.parse(endText) else {
            addError = "Use ss, m:ss or h:mm:ss."
            return
        }
        guard end > start else {
            addError = "The end has to come after the start."
            return
        }
        addError = nil
        queue.setSkipRange(SkipRange(start: start, end: end), enabled: true, for: job.id)
        startText = ""
        endText = ""
    }
}

private struct StateBadge: View {
    let state: QueuedJob.State

    var body: some View {
        Text(title)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var title: String {
        switch state {
        case .probing: return "Reading"
        case .queued: return "Queued"
        case .running: return "Running"
        case .finished: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var color: Color {
        switch state {
        case .probing, .queued: return .secondary
        case .running: return .accentColor
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

private struct ProgressSection: View {
    let progress: UpscaleProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var statusText: String {
        switch progress.phase {
        case .probing:
            return "Reading file…"
        case .compilingShaders:
            // The HQ presets carry very large CNN shaders; the first job pays for this.
            return "Compiling shaders…"
        case .finalizing:
            return "Finishing the file…"
        case .processing:
            var parts: [String] = []
            if let total = progress.totalFrames {
                parts.append("\(progress.framesProcessed) / \(total) frames")
            } else {
                parts.append("\(progress.framesProcessed) frames")
            }
            parts.append(String(format: "%.1f fps", progress.framesPerSecond))
            if let remaining = progress.estimatedTimeRemaining {
                parts.append("\(JobRow.durationText(remaining)) left")
            }
            return parts.joined(separator: "  ·  ")
        }
    }
}
