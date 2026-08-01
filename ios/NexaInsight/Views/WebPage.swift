#if os(iOS)
import SwiftUI
import WebKit

// A WKWebView wrapper, used only for YouTube pages we deliberately do not scrape.
//
// Why a web view rather than resolving a stream ourselves: measured on a live
// watch page, all 30 `adaptiveFormats` arrive with `signatureCipher` and no `url`,
// there are zero progressive `formats`, and no `hlsManifestUrl` — YouTube now
// requires decrypting a signature with logic that lives in its own player JS and
// changes over time. That is the job yt-dlp exists to do. Letting YouTube's player
// run in a web view sidesteps it entirely and cannot break when the cipher rotates.
//
// IMPORTANT — this is unusable on the study screen. The live classroom needs the
// mic open while the source plays, which requires our own voice-chat
// AVAudioSession (see Playback.configureAudioSession). Media inside WebKit is
// outside that session, so the teacher's voice would self-trigger the VAD; and
// `pause()`/`currentMs` would become async round-trips through a JS bridge, where
// the floor arbitration needs them exact and immediate.
struct WebPage: UIViewRepresentable {
    let url: URL
    // Reported so the caller can show its own progress rather than leaving a blank
    // rectangle during the first (large) page load.
    var onLoadingChange: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Keeps the video in the page instead of taking over the screen, so the
        // sheet's own "Add to Nexa" button stays visible next to it.
        config.allowsInlineMediaPlayback = true
        // Nothing autoplays: this screen is for deciding whether to commit to a
        // four-hour episode, and sound starting by itself is hostile.
        config.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoadingChange = onLoadingChange
        // Only reload on a genuine change of address; SwiftUI re-invokes this on
        // every state change, and reloading each time would restart the video.
        guard webView.url?.absoluteString != url.absoluteString, !webView.isLoading else { return }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadingChange: onLoadingChange)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLoadingChange: (Bool) -> Void

        init(onLoadingChange: @escaping (Bool) -> Void) {
            self.onLoadingChange = onLoadingChange
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChange(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChange(false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
        }
    }
}

// Addresses for the pages we hand to YouTube's own player rather than parse.
enum YouTubeWeb {
    // The embed player, not the watch page: no recommendations rail, no comments,
    // and it is the documented way to play a video you do not own.
    static func embed(videoId: String) -> URL? {
        URL(string: "https://www.youtube.com/embed/\(videoId)?playsinline=1&rel=0")
    }

    static func channel(channelId: String) -> URL? {
        guard YouTubeChannelLogic.isValidChannelId(channelId) else { return nil }
        return URL(string: "https://www.youtube.com/channel/\(channelId)")
    }

    // The signed-in user's own subscriptions. This is the one path that reaches
    // them without OAuth — `subscriptions.list?mine=true` rejects an API key, and
    // a full PKCE flow would be a large amount of work for one import.
    //
    // The catch, and it is why this only ever shows rather than imports: we cannot
    // read the page's contents. Cross-origin script injection to scrape someone
    // else's DOM is both fragile and a thing we should not do.
    static let subscriptions = URL(string: "https://www.youtube.com/feed/subscriptions")!
}

// A web page in a sheet, with a way out and a way to the real browser.
//
// Used for the two YouTube pages worth showing but not worth reimplementing: a
// channel's own home, and your signed-in subscriptions feed.
struct WebPageSheet: View {
    let title: String
    let url: URL
    // Shown under the toolbar when the page is only viewable — we cannot read a
    // cross-origin page's contents, so nothing here can feed the library.
    var note: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let note {
                    Text(note)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, NXSpacing.x4)
                        .padding(.vertical, NXSpacing.x2)
                }
                ZStack {
                    WebPage(url: url, onLoadingChange: { loading = $0 })
                    if loading { ProgressView() }
                }
            }
            .background(NXColor.background(scheme))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                // Signing in, or anything else needing a real browser, belongs in
                // Safari rather than in a sheet pretending to be one.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openURL(url) } label: {
                        Image(systemName: "safari")
                    }
                    .accessibilityLabel("Open in Safari")
                }
            }
        }
    }
}
#endif
