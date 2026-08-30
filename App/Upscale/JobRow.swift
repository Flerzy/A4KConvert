import SwiftUI
import UpscaleCore

/// One queue entry: its settings while it waits, its progress while it runs, and its
/// error once it fails.
struct JobRow: View {
    @EnvironmentObject private var queue: JobQueue
    let job: QueuedJob
    @State private var showsFailureDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if job.state == .queued || job.state == .probing {
                settings
            }
            if job.state == .running, let progress = job.progress {
                ProgressSection(progress: progress)
            }
            if let message = job.failureMessage {
                failure(message)
            }
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

    private var settings: some View {
        HStack(spacing: 12) {
            Picker("Preset", selection: presetBinding) {
                ForEach(Preset.all) { preset in
                    Text(preset.name).tag(preset)
                }
            }
            .frame(maxWidth: 190)

            Picker("Scale", selection: scaleBinding) {
                Text("2x").tag(2)
                Text("4x").tag(4)
            }
            .frame(maxWidth: 110)

            Picker("Encoder", selection: encoderBinding) {
                ForEach(VideoEncoder.allCases, id: \.self) { encoder in
                    Text(encoder.displayName).tag(encoder)
                }
            }
            .frame(maxWidth: 220)

            VStack(alignment: .leading, spacing: 0) {
                Text("Quality \(job.settings.encoder.quality)")
                    .font(.caption)
                Slider(value: qualityBinding, in: 20...95, step: 5)
                    .frame(width: 130)
            }

            Button("Output…") { queue.presentSavePanel(for: job) }
                .help(job.settings.output.path)
        }
        .disabled(job.state == .probing)
        .controlSize(.small)
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

    private var encoderBinding: Binding<VideoEncoder> {
        Binding(
            get: { job.settings.encoder.encoder },
            set: { value in queue.update(job.id) { $0.encoder.encoder = value } }
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
