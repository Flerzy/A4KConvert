import SwiftUI
import UpscaleCore

@main
struct UpscaleApp: App {
    @StateObject private var queue = JobQueue(defaults: DefaultsStore.load())

    var body: some Scene {
        WindowGroup("Upscale") {
            ContentView()
                .environmentObject(queue)
                // The settings row carries six controls plus three buttons; below this
                // the pickers start trimming their own labels.
                .frame(minWidth: 900, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Files…") { queue.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            PreviewZoomCommands()
        }

        // One preview window per job, so it can be resized, zoomed, put full screen and
        // closed like any other window while the queue stays visible behind it.
        WindowGroup("Preview", id: PreviewWindow.sceneID, for: UUID.self) { $jobID in
            if let jobID {
                PreviewWindow(jobID: jobID)
                    .environmentObject(queue)
            }
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
    }
}

/// View-menu entries for the focused preview window.
private struct PreviewZoomCommands: Commands {
    @FocusedValue(\.previewZoom) private var zoom

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Zoom In") { zoom?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(zoom == nil)
            Button("Zoom Out") { zoom?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom == nil)
            Button("Actual Size") { zoom?.actualSize() }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(zoom == nil)
            Button("Fit to Window") { zoom?.fit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom == nil)
        }
    }
}
