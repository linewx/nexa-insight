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
    }
}
#endif
