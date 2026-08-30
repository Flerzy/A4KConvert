import AppKit
import UpscaleCore

extension JobQueue {
    /// AppKit file picking lives in the app target so the core stays UI-free.
    @MainActor
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Any file ffmpeg can read is fair game, so the probe decides rather than a
        // type filter that would hide MKVs behind an unhelpful "unsupported" grey-out.
        panel.allowedContentTypes = []
        panel.prompt = "Add"
        panel.message = "Choose video files to upscale"

        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Asks where one job's output should go, defaulting to its current destination.
    @MainActor
    func presentSavePanel(for job: QueuedJob) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.settings.output.lastPathComponent
        panel.directoryURL = job.settings.output.deletingLastPathComponent()
        panel.prompt = "Choose"
        panel.message = "Choose where to write the upscaled file"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        update(job.id) { $0.output = url }
    }

    @MainActor
    func revealInFinder(_ job: QueuedJob) {
        NSWorkspace.shared.activateFileViewerSelecting([job.settings.output])
    }
}
