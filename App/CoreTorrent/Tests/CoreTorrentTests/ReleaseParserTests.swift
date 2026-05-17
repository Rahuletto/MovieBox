import Testing
@testable import CoreTorrent

@Test func parsesDolbyVisionWithHDR10Fallback() {
    let title = "Movie.2026.2160p.BluRay.DV.HDR10.Atmos.H265-GROUP"

    #expect(ReleaseParser.parseQuality(from: title) == .p2160)
    #expect(ReleaseParser.parseHDR(from: title) == .dolbyVisionWithHDR10)
    #expect(ReleaseParser.parseAudio(from: title) == .dolbyAtmos)
    #expect(ReleaseParser.parseCodec(from: title) == .h265)
    #expect(ReleaseParser.parseSource(from: title) == .bluray)
}

@Test func parsesWebDLSDRDefaults() {
    let title = "Movie.2026.1080p.WEB-DL.H264.EAC3-GROUP"

    #expect(ReleaseParser.parseQuality(from: title) == .p1080)
    #expect(ReleaseParser.parseHDR(from: title) == nil)
    #expect(ReleaseParser.parseAudio(from: title) == .eac3)
    #expect(ReleaseParser.parseCodec(from: title) == .h264)
    #expect(ReleaseParser.parseSource(from: title) == .webdl)
}
