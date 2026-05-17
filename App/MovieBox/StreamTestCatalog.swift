// Demos disabled — kept for local playback/HDR/subtitle testing. Re-enable with `#if true`.
#if false

import Foundation
import CorePlayer
import SwiftUI

/// Verified public streams for the Downloads tab demos.
enum StreamTestCatalog {
    enum Poster {
        case image(URL)
        case gradient([Color], symbol: String)
    }

    struct Item: Identifiable, Hashable {
        let id: String
        let title: String
        let tagline: String
        let description: String
        let poster: Poster
        let url: URL
        let sourcePageURL: URL
        let sourceName: String
        let tags: [String]
        let hdrType: PlayerHDRType?

        var isSubtitleDemo: Bool { id == "subtitle-demo" }

        var posterImageURL: URL? {
            if case .image(let url) = poster { return url }
            return nil
        }

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    static func item(id: String) -> Item? {
        all.first { $0.id == id }
    }

    private static let appleHDRBase =
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos"

    private static let bbbPoster = URL(string: "https://peach.blender.org/wp-content/uploads/title_anouncement.jpg")!

    // MARK: - SDR

    static let hlsAdaptive = Item(
        id: "hls-adaptive",
        title: "Bip-Bop Advanced",
        tagline: "Apple · HLS adaptive · SDR",
        description: """
        Apple’s public Bip-Bop sample in fragmented MP4. Exercises multi-bitrate HLS, \
        separate audio renditions, WebVTT subtitles, and ABR switching in AVPlayer.
        """,
        poster: .gradient(
            [Color(red: 0.12, green: 0.22, blue: 0.42), Color(red: 0.08, green: 0.14, blue: 0.28)],
            symbol: "play.tv.fill"
        ),
        url: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!,
        sourcePageURL: URL(string: "https://developer.apple.com/streaming/examples/advanced-stream-fmp4.html")!,
        sourceName: "Apple Developer",
        tags: ["HLS", "ABR", "SDR", "fMP4"],
        hdrType: nil
    )

    static let hlsVOD = Item(
        id: "hls-vod",
        title: "Big Buck Bunny",
        tagline: "Mux · HLS on-demand · SDR",
        description: """
        Mux’s hosted Big Buck Bunny HLS VOD. A straightforward single-program stream \
        for checking basic HLS startup, buffering, and progressive playback.
        """,
        poster: .image(bbbPoster),
        url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
        sourcePageURL: URL(string: "https://test-streams.mux.dev/")!,
        sourceName: "Mux test streams",
        tags: ["HLS", "VOD", "SDR"],
        hdrType: nil
    )

    static let subtitleDemo = Item(
        id: "subtitle-demo",
        title: "Big Buck Bunny",
        tagline: "Mux · Subtitle styling · SDR",
        description: """
        Same Mux HLS stream with MovieBox’s bundled English SRT. Use this to preview \
        cinematic subtitle styling — pill background, fade animations, and Settings presets.
        """,
        poster: .image(bbbPoster),
        url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
        sourcePageURL: URL(string: "https://test-streams.mux.dev/")!,
        sourceName: "Mux test streams",
        tags: ["HLS", "Subtitles", "SDR"],
        hdrType: nil
    )

    // MARK: - HDR

    static let hdr10 = Item(
        id: "hdr10-hls",
        title: "Becoming You",
        tagline: "Apple · HDR10 · HLS",
        description: """
        Apple’s 4K HEVC sample with HDR10 PQ tiers and SDR fallbacks. On an HDR-capable \
        Mac and display, AVPlayer should select the HDR ladder automatically.
        """,
        poster: .gradient(
            [Color(red: 0.45, green: 0.18, blue: 0.12), Color(red: 0.18, green: 0.08, blue: 0.22)],
            symbol: "sun.max.fill"
        ),
        url: URL(string: "\(appleHDRBase)/main.m3u8")!,
        sourcePageURL: URL(string: "https://developer.apple.com/streaming/examples/advanced-stream-dv-atmos.html")!,
        sourceName: "Apple Developer",
        tags: ["HLS", "HDR10", "HEVC", "4K"],
        hdrType: .hdr10
    )

    static let hdr10Plus = Item(
        id: "hdr10plus-hls",
        title: "Becoming You",
        tagline: "Apple · HDR10+ · HLS",
        description: """
        1080p HDR10+ tier from Apple’s sample pack (dynamic HDR metadata). Requires \
        HDR10+ support on your display for the full effect; otherwise plays as HDR10 baseline.
        """,
        poster: .gradient(
            [Color(red: 0.55, green: 0.32, blue: 0.08), Color(red: 0.22, green: 0.10, blue: 0.18)],
            symbol: "sun.max"
        ),
        url: URL(string: "\(appleHDRBase)/Job8208634a-0add-4223-9782-600c14a70339-139240443-hls_bundle_hdrhls785_hdr10plus/prog_index.m3u8")!,
        sourcePageURL: URL(string: "https://developer.apple.com/streaming/examples/advanced-stream-dv-atmos.html")!,
        sourceName: "Apple Developer",
        tags: ["HLS", "HDR10+", "HEVC", "1080p"],
        hdrType: .hdr10Plus
    )

    static let sdrDemos: [Item] = [hlsAdaptive, hlsVOD, subtitleDemo]
    static let hdrDemos: [Item] = [hdr10, hdr10Plus]
    static let all: [Item] = sdrDemos + hdrDemos

    static var bundledSubtitle: URL? {
        Bundle.main.url(forResource: "sample-en", withExtension: "srt")
    }
}

#endif
