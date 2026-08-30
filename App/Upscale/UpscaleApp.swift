import SwiftUI
import UpscaleCore

@main
struct UpscaleApp: App {
    @StateObject private var queue = JobQueue()

    var body: some Scene {
        WindowGroup("Upscale") {
            ContentView()
                .environmentObject(queue)
                .frame(minWidth: 760, minHeight: 460)
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
