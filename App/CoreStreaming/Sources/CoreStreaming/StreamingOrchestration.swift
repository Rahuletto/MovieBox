import Foundation
import CoreTorrent

@MainActor
public protocol StreamingOrchestration: AnyObject, Sendable {
    func startStream(
        torrent: TorrentResult,
        progressHandler: @escaping @Sendable (Double, Double, Int) -> Void
    ) async throws -> URL

    func stop() async
    func progress() async -> Double
    func contiguousPiecesFromStart() async -> Int
    func contiguousBytesFromStreamStart() async -> Int64
    func verifiedMediaBytesFromStart() async -> Int64
    func streamHeadContiguousBytes() async -> Int64
    func streamTargetNeedsTailProbe() async -> Bool
    func streamIndexProbeLabel() async -> String
    func streamTailPieceCount() async -> Int
    func streamTailPiecesVerified() async -> Int
    func streamTailPiecesProgress() async -> Double
    func isStreamTailPieceReady() async -> Bool
    func hasMinimumPlaybackHead() async -> Bool
    func allStreamPiecesVerified() async -> Bool
    func downloadSpeed() async -> Double
    func peerCount() async -> Int
    func transferringPeerCount() async -> Int
}

extension StreamingOrchestrator: StreamingOrchestration {}
