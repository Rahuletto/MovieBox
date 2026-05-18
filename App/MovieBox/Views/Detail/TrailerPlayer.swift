import SwiftUI
import WebKit

struct TrailerWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsAirPlayForMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 16
        webView.layer?.masksToBounds = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.load(URLRequest(url: url))
    }
}

struct FullScreenTrailerPlayer: View {
    let videoURL: URL
    let onDismiss: () -> Void

    private var embedURL: URL? {
        YouTubeURL.embedURL(for: videoURL)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let embedURL {
                TrailerWebView(url: embedURL)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView("Unable to load trailer", systemImage: "play.slash")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(24)
            .transition(.opacity)
        }
    }
}
