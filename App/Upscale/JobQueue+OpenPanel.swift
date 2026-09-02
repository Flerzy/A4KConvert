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

        // The save panel's overwrite prompt reads like any other replace, but writing
        // over the source would truncate it before either ffmpeg could read it.
        guard url.resolvingSymlinksInPath().standardizedFileURL
            != job.input.resolvingSymlinksInPath().standardizedFileURL
        else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That is the source file"
            alert.informativeText = "Upscale reads the original while it writes, so the "
                + "output has to be a different file. Choose another name."
            alert.runModal()
            return
        }

        update(job.id) { $0.output = url }
    }

    /// Asks for the folder new jobs write into. Cancelling leaves the current one.
    @MainActor
    func presentDefaultFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaults.outputFolder
        panel.prompt = "Choose"
        panel.message = "Choose where new jobs write their output"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.outputFolder = url
    }

    @MainActor
    func revealInFinder(_ job: QueuedJob) {
        NSWorkspace.shared.activateFileViewerSelecting([job.settings.output])
    }
}
