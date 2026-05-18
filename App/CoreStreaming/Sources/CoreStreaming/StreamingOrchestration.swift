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
    func streamHeadContiguousBytes() async -> Int64
    func downloadSpeed() async -> Double
    func peerCount() async -> Int
}

extension StreamingOrchestrator: StreamingOrchestration {}
