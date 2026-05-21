import CoreMetadata
import CorePlayer
import CoreStreaming
import CoreTorrent
import XCTest
@testable import MovieBoxCore

@MainActor
final class PersistentPlaybackControllerTests: XCTestCase {
    func testStartDoesNotPresentPlayer() {
        let appServices = AppServices()
        let playerState = PlayerState()
        let torrent = makeTorrent(title: "Test.Release.2024.1080p.WEB-DL.x264")

        let request = PersistentPlaybackStartRequest(
            mode: .single(torrent),
            movieId: 42,
            mediaKind: .movie,
            allTorrents: [torrent],
            posterURL: nil,
            title: "Test Movie",
            playback: PlaybackSettings(appearance: .cinematic, fontSize: 20),
            waitTimeout: 1
        )

        let result = appServices.persistentPlayback.start(
            request: request,
            appServices: appServices,
            playerState: playerState
        )

        XCTAssertEqual(result, .started)
        XCTAssertFalse(playerState.isPresented)
        XCTAssertTrue(appServices.persistentPlayback.isActive)
    }

    func testSecondTorrentNeedsConfirmation() {
        let appServices = AppServices()
        let playerState = PlayerState()
        let first = makeTorrent(title: "First.Release.2024.1080p.WEB-DL.x264")
        let second = makeTorrent(title: "Second.Release.2024.1080p.WEB-DL.x264")

        let firstRequest = PersistentPlaybackStartRequest(
            mode: .single(first),
            movieId: 1,
            mediaKind: .movie,
            allTorrents: [first],
            posterURL: nil,
            title: "First",
            playback: PlaybackSettings(appearance: .cinematic, fontSize: 20)
        )
        _ = appServices.persistentPlayback.start(
            request: firstRequest,
            appServices: appServices,
            playerState: playerState
        )

        let secondRequest = PersistentPlaybackStartRequest(
            mode: .single(second),
            movieId: 2,
            mediaKind: .movie,
            allTorrents: [second],
            posterURL: nil,
            title: "Second",
            playback: PlaybackSettings(appearance: .cinematic, fontSize: 20)
        )
        let result = appServices.persistentPlayback.start(
            request: secondRequest,
            appServices: appServices,
            playerState: playerState
        )

        XCTAssertEqual(result, .needsConfirmation)
        XCTAssertNotNil(appServices.persistentPlayback.pendingRequest)
    }

    private func makeTorrent(title: String) -> TorrentResult {
        TorrentResult(
            title: title,
            magnetURI: "magnet:?xt=urn:btih:0e876ce2a1a504f849ca72a5e2bc07347b3bc957",
            quality: .p1080,
            hdrType: nil,
            codec: .h264,
            audioFormat: nil,
            source: .webdl,
            sizeBytes: 1_000_000,
            seeders: 10,
            leechers: 1,
            trackerSource: .torrentio,
            infoHash: "0e876ce2a1a504f849ca72a5e2bc07347b3bc957",
            language: "en"
        )
    }
}
