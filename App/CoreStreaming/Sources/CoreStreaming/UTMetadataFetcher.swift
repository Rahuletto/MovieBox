import CryptoKit
import Foundation
import Network

private let metadataPieceSize = 16 * 1024
private let extendedMessageID: UInt8 = 20
private let extendedHandshakeID: UInt8 = 0

/// Fetches torrent metadata from peers via BEP 9 `ut_metadata` when web caches have no `.torrent` file.
public enum UTMetadataFetcher {

    public static func fetch(
        infoHash: String,
        trackers: [String],
        peerId: String
    ) async throws -> TorrentMetadata {
        let normalized = infoHash.lowercased()
        let peers = await discoverPeers(infoHash: normalized, trackers: trackers, peerId: peerId)
        guard !peers.isEmpty else {
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }

        return try await withThrowingTaskGroup(of: TorrentMetadata.self) { group in
            for peer in peers.prefix(12) {
                group.addTask {
                    try await fetchFromPeer(
                        peer: peer,
                        infoHash: normalized,
                        peerId: peerId,
                        trackers: trackers
                    )
                }
            }

            var lastError: Error = TorrentMetadataFetcher.FetchError.torrentFileUnavailable
            for try await result in group {
                group.cancelAll()
                return result
            }
            while let next = await group.nextResult() {
                if case .failure(let error) = next { lastError = error }
            }
            throw lastError
        }
    }

    private static func discoverPeers(
        infoHash: String,
        trackers: [String],
        peerId: String
    ) async -> [PeerInfo] {
        var peers: [PeerInfo] = []
        var seen = Set<String>()
        let udp = UDPTrackerClient()
        let http = TrackerClient()

        for tracker in trackers {
            if tracker.hasPrefix("udp://") {
                if let response = try? await udp.announce(
                    trackerURL: tracker,
                    infoHash: infoHash,
                    peerId: peerId,
                    port: 6881,
                    left: 1,
                    event: .started,
                    numWant: 80
                ) {
                    for peer in response.peers {
                        let key = "\(peer.ip):\(peer.port)"
                        if seen.insert(key).inserted { peers.append(peer) }
                    }
                }
            } else if tracker.hasPrefix("http") {
                if let response = try? await http.announce(
                    trackerURL: tracker,
                    infoHash: infoHash,
                    peerId: peerId,
                    port: 6881,
                    left: 1,
                    event: .started,
                    numWant: 80
                ) {
                    for peer in response.peers {
                        let key = "\(peer.ip):\(peer.port)"
                        if seen.insert(key).inserted { peers.append(peer) }
                    }
                }
            }
        }
        return peers
    }

    private static func fetchFromPeer(
        peer: PeerInfo,
        infoHash: String,
        peerId: String,
        trackers: [String]
    ) async throws -> TorrentMetadata {
        let session = MetadataPeerSession(peer: peer, infoHash: infoHash, peerId: peerId)
        let infoData = try await session.fetchInfoDictionary()
        return try TorrentFileParser.parse(
            infoBencoded: infoData,
            expectedInfoHash: infoHash,
            trackers: trackers
        )
    }
}

// MARK: - Single peer session

private final class MetadataPeerSession: @unchecked Sendable {
    private let peer: PeerInfo
    private let infoHash: String
    private let peerId: String
    private var connection: NWConnection?
    private var buffer = Data()
    private var utMetadataExtensionID: UInt8 = 1

    init(peer: PeerInfo, infoHash: String, peerId: String) {
        self.peer = peer
        self.infoHash = infoHash
        self.peerId = peerId
    }

    func fetchInfoDictionary() async throws -> Data {
        guard peer.port > 0, peer.port < 65536,
              let port = NWEndpoint.Port(rawValue: UInt16(peer.port)) else {
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }

        let connection = NWConnection(host: NWEndpoint.Host(peer.ip), port: port, using: .tcp)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        try await sendHandshake()
        try await readHandshake()

        let ourHandshake = BencodeParser.encode(.dictionary([
            "m": .dictionary(["ut_metadata": .integer(1)]),
            "reqq": .integer(255),
        ]))
        try await sendExtended(id: extendedHandshakeID, payload: ourHandshake)

        guard let metadataSize = try await readUntilMetadataOffered() else {
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }

        let pieceCount = (metadataSize + metadataPieceSize - 1) / metadataPieceSize
        var assembled = Data()
        assembled.reserveCapacity(metadataSize)

        for piece in 0..<pieceCount {
            let request = BencodeParser.encode(.dictionary([
                "msg_type": .integer(0),
                "piece": .integer(Int64(piece)),
            ]))
            try await sendExtended(id: utMetadataExtensionID, payload: request)
            let chunk = try await readMetadataPiece(expectedPiece: piece)
            assembled.append(chunk)
        }

        connection.cancel()
        guard assembled.count == metadataSize else {
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }
        guard assembled.sha1Hex == infoHash else {
            throw TorrentMetadataFetcher.FetchError.infoHashMismatch
        }
        return assembled
    }

    private func sendHandshake() async throws {
        var handshake = Data()
        handshake.append(19)
        handshake.append(contentsOf: "BitTorrent protocol".utf8)
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10
        handshake.append(contentsOf: reserved)
        handshake.append(contentsOf: hexToData(infoHash))
        handshake.append(BitTorrentPeerID.data(for: peerId))
        try await send(handshake)
    }

    private func readHandshake() async throws {
        let data = try await readExact(68)
        guard data.count >= 68,
              String(data: data[1..<20], encoding: .utf8) == "BitTorrent protocol" else {
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }
    }

    private func readUntilMetadataOffered() async throws -> Int? {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let packet = try await readNextPacket() {
                if packet.id == extendedMessageID,
                   packet.extendedID == extendedHandshakeID,
                   let dict = try? BencodeParser.parse(packet.payload).dictionary {
                    if let extensions = dict["m"]?.dictionary,
                       let id = extensions["ut_metadata"]?.integer {
                        utMetadataExtensionID = UInt8(clamping: id)
                    }
                    if let size = dict["metadata_size"]?.integer, size > 0 {
                        return Int(size)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func readMetadataPiece(expectedPiece: Int) async throws -> Data {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let packet = try await readNextPacket() {
                guard packet.id == extendedMessageID,
                      packet.extendedID == utMetadataExtensionID else { continue }

                guard let headerEnd = packet.payload.firstIndex(of: UInt8(ascii: "e")) else { continue }
                let header = packet.payload[..<headerEnd.advanced(by: 1)]
                guard let dict = try? BencodeParser.parse(Data(header)).dictionary else { continue }

                if dict["msg_type"]?.integer == 2 { throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable }
                guard dict["msg_type"]?.integer == 1,
                      Int(dict["piece"]?.integer ?? -1) == expectedPiece else { continue }

                let bodyStart = headerEnd + 1
                return Data(packet.payload[bodyStart...])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
    }

    private struct Packet {
        let id: UInt8
        let extendedID: UInt8
        let payload: Data
    }

    private func readNextPacket() async throws -> Packet? {
        while buffer.count < 5 {
            try await appendReceive()
            if buffer.count < 5 { return nil }
        }

        let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
        if length == 0 {
            buffer.removeFirst(4)
            return nil
        }
        let total = 4 + length
        while buffer.count < total {
            try await appendReceive()
            if buffer.count < total { return nil }
        }

        let message = buffer.prefix(total)
        buffer.removeFirst(total)
        let id = message[4]
        guard id == extendedMessageID, length >= 2 else { return nil }
        let extID = message[5]
        let payload = Data(message.dropFirst(6))
        return Packet(id: id, extendedID: extID, payload: payload)
    }

    private func appendReceive() async throws {
        guard let connection else { return }
        let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: data)
            }
        }
        if let chunk { buffer.append(chunk) }
    }

    private func sendExtended(id: UInt8, payload: Data) async throws {
        var message = Data()
        let length = UInt32(2 + payload.count)
        message.append(contentsOf: length.bigEndianBytes)
        message.append(extendedMessageID)
        message.append(id)
        message.append(payload)
        try await send(message)
    }

    private func send(_ data: Data) async throws {
        guard let connection else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func readExact(_ count: Int) async throws -> Data {
        let deadline = Date().addingTimeInterval(10)
        while buffer.count < count {
            if Date() > deadline { throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable }
            try await appendReceive()
        }
        let slice = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(slice)
    }

    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        return data
    }
}

private extension Data {
    var sha1Hex: String {
        Insecure.SHA1.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
