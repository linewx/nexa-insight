#if os(iOS)
import SwiftUI

@main
struct NexaInsightApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @State private var store: EpisodeStore? = try? EpisodeStore()

    var body: some View {
        Group {
            if let store {
                LibraryView(store: store, settings: settings)
            } else {
                Text("Storage unavailable")
            }
        }
        // Batch extraction is gone, but a device that ran an earlier build still holds
        // its rows — hundreds per episode, filling the notes list and marking up the
        // transcript with words nobody chose. Cleared once, on launch, because nothing
        // will regenerate them and there is no moment later that is more obviously right.
        .task {
            guard let store else { return }
            let removed = (try? store.purgeAutoExpressions()) ?? 0
            if removed > 0 { NexaLog.log("purged \(removed) batch-extracted expressions") }
        }
    }
}
#endif
