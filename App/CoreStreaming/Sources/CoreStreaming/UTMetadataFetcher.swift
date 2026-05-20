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
            for peer in peers.prefix(6) {
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
            while let result = await group.nextResult() {
                switch result {
                case .success(let metadata):
                    group.cancelAll()
                    return metadata
                case .failure(let error as TorrentMetadataFetcher.FetchError):
                    if case .infoHashMismatch = error {
                        group.cancelAll()
                        throw error
                    }
                    lastError = error
                case .failure(let error):
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func discoverPeers(
        infoHash: String,
        trackers: [String],
        peerId: String
    ) async -> [PeerInfo] {
        let capped = cappedTrackersForDiscovery(trackers)
        TorrentLog.debug("[discoverPeers] InfoHash: \(infoHash), announcing to \(capped.count) trackers (of \(trackers.count))")

        let deadline = Date().addingTimeInterval(4)
        let minPeers = 32

        return await withTaskGroup(of: [PeerInfo].self) { group in
            let udp = UDPTrackerClient()
            let http = TrackerClient()

            for tracker in capped {
                group.addTask {
                    if tracker.hasPrefix("udp://") {
                        do {
                            let response = try await udp.announce(
                                trackerURL: tracker,
                                infoHash: infoHash,
                                peerId: peerId,
                                port: 6881,
                                left: 1,
                                event: .started,
                                numWant: 80
                            )
                            return response.peers
                        } catch {
                            return []
                        }
                    } else if tracker.hasPrefix("http") {
                        do {
                            let response = try await http.announce(
                                trackerURL: tracker,
                                infoHash: infoHash,
                                peerId: peerId,
                                port: 6881,
                                left: 1,
                                event: .started,
                                numWant: 80
                            )
                            return response.peers
                        } catch {
                            return []
                        }
                    }
                    return []
                }
            }

            var allPeers: [PeerInfo] = []
            var seen = Set<String>()
            while let peers = await group.next() {
                for peer in peers {
                    let key = "\(peer.ip):\(peer.port)"
                    if seen.insert(key).inserted {
                        allPeers.append(peer)
                    }
                }
                if Date() >= deadline || allPeers.count >= minPeers {
                    group.cancelAll()
                    break
                }
            }
            TorrentLog.debug("[discoverPeers] Done — \(allPeers.count) unique peers")
            return allPeers
        }
    }

    private static func cappedTrackersForDiscovery(_ trackers: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ url: String) {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            ordered.append(trimmed)
        }
        for tracker in trackers where tracker.lowercased().hasPrefix("udp://") { append(tracker) }
        for tracker in trackers where tracker.lowercased().hasPrefix("http") { append(tracker) }
        for tracker in trackers { append(tracker) }
        return Array(ordered.prefix(25))
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

private actor MetadataPeerSession {
    private static let maxWireBufferBytes = 512 * 1024
    private static let maxWireMessageBytes = 262_144

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

        let parameters = NWParameters.tcp
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 5
        parameters.defaultProtocolStack.transportProtocol = tcpOptions

        let connection = NWConnection(host: NWEndpoint.Host(peer.ip), port: port, using: parameters)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ConnectionContinuationGate(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.finish()
                case .failed(let error):
                    gate.finish(throwing: error)
                case .waiting(_):
                    gate.finish(throwing: TorrentMetadataFetcher.FetchError.torrentFileUnavailable)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            // Set an explicit connection safety timeout of 5 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                gate.finish(throwing: TorrentMetadataFetcher.FetchError.torrentFileUnavailable)
            }
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
        handshake.append(contentsOf: HexEncoding.data(fromHex: infoHash))
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
        var idleRounds = 0
        while idleRounds < 120 {
            if let packet = try parseBufferedPacket() {
                return packet
            }
            guard connection != nil else { return nil }
            let sizeBefore = buffer.count
            try await appendReceive()
            if buffer.count == sizeBefore {
                idleRounds += 1
            } else {
                idleRounds = 0
            }
        }
        return nil
    }

    private func parseBufferedPacket() throws -> Packet? {
        guard buffer.count >= 4 else { return nil }

        if buffer.count > Self.maxWireBufferBytes {
            resetConnection()
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }

        let start = buffer.startIndex
        let length = UInt32(buffer[start]) << 24 | UInt32(buffer[start + 1]) << 16
            | UInt32(buffer[start + 2]) << 8 | UInt32(buffer[start + 3])

        if length == 0 {
            buffer.removeSubrange(0..<4)
            return nil
        }

        guard length <= Self.maxWireMessageBytes else {
            TorrentLog.warn("[UTMetadata] Invalid wire length \(length) from \(peer.ip):\(peer.port) — resetting session")
            resetConnection()
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }

        let total = 4 + Int(length)
        guard total > 4, buffer.count >= total else { return nil }

        let message = Data(buffer[start..<(start + total)])
        guard message.count >= 6 else {
            resetConnection()
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }

        let base = message.startIndex
        let id = message[message.index(base, offsetBy: 4)]
        guard id == extendedMessageID, length >= 2 else {
            buffer.removeSubrange(0..<total)
            return nil
        }

        buffer.removeSubrange(0..<total)
        let extID = message[message.index(base, offsetBy: 5)]
        let payload = Data(message.dropFirst(6))
        return Packet(id: id, extendedID: extID, payload: payload)
    }

    private func resetConnection() {
        buffer.removeAll(keepingCapacity: false)
        connection?.cancel()
        connection = nil
    }

    private func appendReceive() async throws {
        guard let connection else {
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }
        let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
            let gate = ReceiveContinuationGate(continuation: continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    gate.finish(throwing: error)
                } else {
                    gate.finish(returning: data)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 10.0) {
                gate.finish(throwing: TorrentMetadataFetcher.FetchError.torrentFileUnavailable)
            }
        }
        if let chunk, !chunk.isEmpty {
            buffer.append(chunk)
            if buffer.count > Self.maxWireBufferBytes {
                resetConnection()
                throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
            }
        }
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
        guard let connection else {
            throw TorrentMetadataFetcher.FetchError.torrentFileUnavailable
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = SendContinuationGate(continuation: continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    gate.finish(throwing: error)
                } else {
                    gate.finish()
                }
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
        buffer.removeSubrange(0..<count)
        return Data(slice)
    }

}

private extension Data {
    var sha1Hex: String {
        Insecure.SHA1.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

private final class SendContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish() {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume()
    }

    func finish(throwing error: Error) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

private final class ConnectionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var connection: NWConnection?

    init(continuation: CheckedContinuation<Void, Error>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish() {
        lock.lock()
        guard let continuation = self.continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        self.connection = nil
        lock.unlock()
        continuation.resume()
    }

    func finish(throwing error: Error) {
        lock.lock()
        guard let continuation = self.continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let conn = self.connection
        self.connection = nil
        lock.unlock()
        conn?.cancel()
        continuation.resume(throwing: error)
    }
}

private final class ReceiveContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?

    init(continuation: CheckedContinuation<Data?, Error>) {
        self.continuation = continuation
    }

    func finish(returning value: Data?) {
        lock.lock()
        guard let continuation = self.continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }

    func finish(throwing error: Error) {
        lock.lock()
        guard let continuation = self.continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
