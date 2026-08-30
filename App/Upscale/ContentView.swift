import SwiftUI
import UniformTypeIdentifiers
import UpscaleCore

struct ContentView: View {
    @EnvironmentObject private var queue: JobQueue
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let environmentError = queue.environmentError {
                EnvironmentErrorBanner(message: environmentError)
            }
            content
            Divider()
            Toolbar()
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if queue.jobs.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(queue.jobs) { job in
                    JobRow(job: job)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }

    /// Drops arrive as promises; resolve them all, then hand the URLs to the queue.
    private func load(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            queue.add(urls)
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop video files here")
                .font(.title3)
            Text("Any container ffmpeg can read, including MKV. 8-bit SDR only.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EnvironmentErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.15))
    }
}

private struct Toolbar: View {
    @EnvironmentObject private var queue: JobQueue

    var body: some View {
        HStack {
            Button("Add Files…") { queue.presentOpenPanel() }
                .disabled(!queue.canRun)
            Button("Clear Finished") { queue.removeFinished() }
                .disabled(!queue.jobs.contains { $0.state.isTerminal })
            Spacer()
            if queue.isRunning {
                Button("Cancel All", role: .destructive) { queue.cancelAll() }
            }
            Button(queue.isRunning ? "Running…" : "Start") { queue.start() }
                .keyboardShortcut(.return)
                .disabled(queue.isRunning || !queue.canRun || !queue.jobs.contains { $0.state == .queued })
        }
        .padding(10)
    }
}
