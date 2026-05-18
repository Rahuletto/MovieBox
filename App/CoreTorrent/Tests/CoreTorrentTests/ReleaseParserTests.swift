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

@Test func resolveQualityPrefersTitleWhenExplicit() {
    #expect(ReleaseParser.resolveQuality(indexerLabel: "2160p", title: "Movie.2026.1080p.WEB-DL") == .p1080)
    #expect(ReleaseParser.resolveQuality(indexerLabel: "1080p", title: "Movie.2026.720p.WEB-DL") == .p720)
    #expect(ReleaseParser.resolveQuality(indexerLabel: "1080p", title: "Movie.2026.720p.AMZN.WEB-DL") == .p720)
}

@Test func resolveQualityUsesIndexerWhenTitleHasNoResolution() {
    #expect(ReleaseParser.resolveQuality(indexerLabel: "2160p", title: "Movie.2026.WEB-DL.H265-GROUP") == .p2160)
    #expect(ReleaseParser.resolveQuality(indexerLabel: "720p", title: "Movie.2026.WEB-DL-GROUP") == .p720)
}

@Test func parsesWebDLSDRDefaults() {
    let title = "Movie.2026.1080p.WEB-DL.H264.EAC3-GROUP"

    #expect(ReleaseParser.parseQuality(from: title) == .p1080)
    #expect(ReleaseParser.parseHDR(from: title) == nil)
    #expect(ReleaseParser.parseAudio(from: title) == .eac3)
    #expect(ReleaseParser.parseCodec(from: title) == .h264)
    #expect(ReleaseParser.parseSource(from: title) == .webdl)
}
