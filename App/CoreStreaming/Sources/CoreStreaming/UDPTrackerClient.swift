import Foundation
import Network

// MARK: - UDP Tracker Client

public actor UDPTrackerClient {
    private var connectionId: UInt64 = 0
    private var connectionExpiry: Date = Date.distantPast

    public init() {}

    public func announce(
        trackerURL: String,
        infoHash: String,
        peerId: String,
        port: Int,
        uploaded: Int64 = 0,
        downloaded: Int64 = 0,
        left: Int64 = 0,
        event: TrackerEvent = .started,
        numWant: Int = 50
    ) async throws -> TrackerResponse {
        guard let url = URLComponents(string: trackerURL),
              let host = url.host,
              let trackerPort = url.port else {
            throw UDPTrackerError.invalidURL
        }

        let connId = try await connect(host: host, port: trackerPort)

        let transactionId = UInt32.random(in: 1...UInt32.max)

        var data = Data()
        data.append(contentsOf: connId.bigEndianBytes)
        data.append(contentsOf: UInt32(1).bigEndianBytes)
        data.append(contentsOf: transactionId.bigEndianBytes)
        data.append(contentsOf: hexToData(infoHash))
        let peerIdData = hexToData(String(peerId.prefix(40)))
        data.append(contentsOf: peerIdData)
        data.append(contentsOf: downloaded.bigEndianBytes)
        data.append(contentsOf: left.bigEndianBytes)
        data.append(contentsOf: uploaded.bigEndianBytes)
        data.append(contentsOf: UInt32(event.rawValue).bigEndianBytes)
        data.append(contentsOf: UInt32(0).bigEndianBytes)
        data.append(contentsOf: UInt32(0).bigEndianBytes)
        data.append(contentsOf: UInt32(numWant).bigEndianBytes)
        data.append(contentsOf: UInt16(port).bigEndianBytes)

        let response = try await sendUDP(host: host, port: trackerPort, data: data)

        guard response.count >= 20 else {
            throw UDPTrackerError.invalidResponse
        }

        let responseAction = response.readUInt32(at: 0)
        guard responseAction == 1 else {
            throw UDPTrackerError.unexpectedAction
        }

        let responseTransactionId = response.readUInt32(at: 4)
        guard responseTransactionId == transactionId else {
            throw UDPTrackerError.transactionMismatch
        }

        let interval = Int(response.readUInt32(at: 8))
        let leechers = Int(response.readUInt32(at: 12))
        let seeders = Int(response.readUInt32(at: 16))

        var peers: [PeerInfo] = []
        var index = 20
        while index + 6 <= response.count {
            let ip = "\(response[index]).\(response[index + 1]).\(response[index + 2]).\(response[index + 3])"
            let peerPort = (Int(response[index + 4]) << 8) | Int(response[index + 5])
            peers.append(PeerInfo(ip: ip, port: peerPort, peerId: nil))
            index += 6
        }

        return TrackerResponse(
            interval: interval,
            seeders: seeders,
            leechers: leechers,
            peers: peers
        )
    }

    private func connect(host: String, port: Int) async throws -> UInt64 {
        if Date.now < connectionExpiry {
            return connectionId
        }

        let transactionId = UInt32.random(in: 1...UInt32.max)
        let magicConnectionId: UInt64 = 0x41727101980

        var data = Data()
        data.append(contentsOf: magicConnectionId.bigEndianBytes)
        data.append(contentsOf: UInt32(0).bigEndianBytes)
        data.append(contentsOf: transactionId.bigEndianBytes)

        let response = try await sendUDP(host: host, port: port, data: data)

        guard response.count >= 16 else {
            throw UDPTrackerError.invalidResponse
        }

        let responseAction = response.readUInt32(at: 0)
        guard responseAction == 0 else {
            throw UDPTrackerError.unexpectedAction
        }

        let responseTransactionId = response.readUInt32(at: 4)
        guard responseTransactionId == transactionId else {
            throw UDPTrackerError.transactionMismatch
        }

        connectionId = response.readUInt64(at: 8)
        connectionExpiry = Date.now.addingTimeInterval(60)

        return connectionId
    }

    private func sendUDP(host: String, port: Int, data: Data) async throws -> Data {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw UDPTrackerError.invalidURL
        }

        let connection = NWConnection(host: nwHost, port: nwPort, using: .udp)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                    })

                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { responseData, _, _, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let responseData else {
                            continuation.resume(throwing: UDPTrackerError.noResponse)
                            return
                        }
                        continuation.resume(returning: responseData)
                    }
                }
                if case .failed(let error) = state {
                    continuation.resume(throwing: error)
                }
            }

            connection.start(queue: .main)

            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                connection.cancel()
                continuation.resume(throwing: UDPTrackerError.timeout)
            }
        }
    }

    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteString = String(hex[index..<nextIndex])
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }
}

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func readUInt64(at offset: Int) -> UInt64 {
        UInt64(self[offset]) << 56 | UInt64(self[offset + 1]) << 48 | UInt64(self[offset + 2]) << 40 | UInt64(self[offset + 3]) << 32 |
        UInt64(self[offset + 4]) << 24 | UInt64(self[offset + 5]) << 16 | UInt64(self[offset + 6]) << 8 | UInt64(self[offset + 7])
    }
}

extension UInt64 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return [
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return [
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}

extension Int64 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return [
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}

public enum UDPTrackerError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case unexpectedAction
    case transactionMismatch
    case noResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid UDP tracker URL"
        case .invalidResponse: "Invalid UDP tracker response"
        case .unexpectedAction: "Unexpected action in response"
        case .transactionMismatch: "Transaction ID mismatch"
        case .noResponse: "No response from tracker"
        case .timeout: "UDP tracker request timed out"
        }
    }
}
