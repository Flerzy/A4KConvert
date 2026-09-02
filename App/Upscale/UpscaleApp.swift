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
        }
    }
}
