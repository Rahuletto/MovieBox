import CoreMetadata
import Foundation
import Testing

@Test func prefersOdycdnOverVideoOnlyProxy() {
    let selection = TrailerStreamPicker.pickPlayable(from: TrailerStreamPicker.Response(
        videoStreams: [
            TrailerStreamPicker.Stream(
                url: "https://proxy.piped.private.coffee/videoplayback?itag=137",
                format: "MPEG_4",
                quality: "1080p",
                videoOnly: true
            ),
            TrailerStreamPicker.Stream(
                url: "https://player.odycdn.com/v6/streams/abc/720.mp4",
                format: "MP4",
                quality: "720p",
                videoOnly: false
            ),
        ]
    ))
    #expect(selection?.url.absoluteString.contains("odycdn") == true)
    #expect(selection?.needsRelay == false)
}

@Test func prefersMuxedProxyOverVideoOnly() {
    let selection = TrailerStreamPicker.pickPlayable(from: TrailerStreamPicker.Response(
        videoStreams: [
            TrailerStreamPicker.Stream(
                url: "https://proxy.piped.private.coffee/videoplayback?itag=137",
                format: "MPEG_4",
                quality: "1080p",
                videoOnly: true
            ),
            TrailerStreamPicker.Stream(
                url: "https://proxy.piped.private.coffee/videoplayback?itag=18",
                format: "MPEG_4",
                quality: "360p",
                videoOnly: false
            ),
        ]
    ))
    #expect(selection?.url.absoluteString.contains("itag=18") == true)
    #expect(selection?.needsRelay == true)
}

@Test func rejectsVideoOnlyProxyOnly() {
    let selection = TrailerStreamPicker.pickPlayable(from: TrailerStreamPicker.Response(
        videoStreams: [
            TrailerStreamPicker.Stream(
                url: "https://proxy.piped.private.coffee/videoplayback?itag=137",
                format: "MPEG_4",
                quality: "1080p",
                videoOnly: true
            ),
        ]
    ))
    #expect(selection == nil)
}
