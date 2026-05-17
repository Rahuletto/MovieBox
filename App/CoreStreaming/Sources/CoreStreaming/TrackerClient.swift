import Foundation

// MARK: - Tracker Client

public actor TrackerClient {
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

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
        guard var components = URLComponents(string: trackerURL) else {
            throw TrackerError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "info_hash", value: hexToPercentEncoded(infoHash)),
            URLQueryItem(name: "peer_id", value: peerId),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "uploaded", value: String(uploaded)),
            URLQueryItem(name: "downloaded", value: String(downloaded)),
            URLQueryItem(name: "left", value: String(left)),
            URLQueryItem(name: "compact", value: "1"),
            URLQueryItem(name: "no_peer_id", value: "0"),
            URLQueryItem(name: "event", value: httpEventString(event)),
            URLQueryItem(name: "numwant", value: String(numWant))
        ]

        guard let url = components.url else {
            throw TrackerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("BitTorrent/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw TrackerError.requestFailed
        }

        return try decodeTrackerResponse(data)
    }

    private func decodeTrackerResponse(_ data: Data) throws -> TrackerResponse {
        if let bencode = try? BencodeParser.parse(data) {
            return try parseBencodeResponse(bencode)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseJSONResponse(json)
        }

        throw TrackerError.invalidResponse
    }

    private func parseBencodeResponse(_ value: BencodeValue) throws -> TrackerResponse {
        guard let dict = value.dictionary else {
            throw TrackerError.invalidResponse
        }

        if let failureReason = dict["failure reason"]?.string {
            throw TrackerError.trackerFailure(failureReason)
        }

        let interval = dict["interval"]?.integer ?? 1800
        let complete = dict["complete"]?.integer ?? 0
        let incomplete = dict["incomplete"]?.integer ?? 0

        var peers: [PeerInfo] = []

        if case .string(let peerData) = dict["peers"] {
            peers = parseCompactPeers(peerData)
        } else if case .list(let peerList) = dict["peers"] {
            for peerValue in peerList {
                if let peerDict = peerValue.dictionary {
                    let ip = peerDict["ip"]?.string ?? ""
                    let port = peerDict["port"]?.integer ?? 0
                    let peerId = peerDict["peer id"]?.string
                    peers.append(PeerInfo(ip: ip, port: Int(port), peerId: peerId))
                }
            }
        }

        return TrackerResponse(
            interval: Int(interval),
            seeders: Int(complete),
            leechers: Int(incomplete),
            peers: peers
        )
    }

    private func parseCompactPeers(_ data: Data) -> [PeerInfo] {
        var peers: [PeerInfo] = []
        var index = data.startIndex

        while index + 6 <= data.endIndex {
            let ipBytes = [data[index], data[index + 1], data[index + 2], data[index + 3]]
            let ip = "\(ipBytes[0]).\(ipBytes[1]).\(ipBytes[2]).\(ipBytes[3])"

            let port = (Int(data[index + 4]) << 8) | Int(data[index + 5])
            peers.append(PeerInfo(ip: ip, port: port, peerId: nil))

            index += 6
        }

        return peers
    }

    private func parseJSONResponse(_ json: [String: Any]) -> TrackerResponse {
        let interval = json["interval"] as? Int ?? 1800
        let complete = json["complete"] as? Int ?? 0
        let incomplete = json["incomplete"] as? Int ?? 0

        var peers: [PeerInfo] = []
        if let peerList = json["peers"] as? [[String: Any]] {
            for peerDict in peerList {
                let ip = peerDict["ip"] as? String ?? ""
                let port = peerDict["port"] as? Int ?? 0
                let peerId = peerDict["peer_id"] as? String
                peers.append(PeerInfo(ip: ip, port: port, peerId: peerId))
            }
        }

        return TrackerResponse(
            interval: interval,
            seeders: complete,
            leechers: incomplete,
            peers: peers
        )
    }

    private func hexToPercentEncoded(_ hex: String) -> String {
        var result = ""
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byte = hex[index..<nextIndex]
            result += "%" + byte
            index = nextIndex
        }
        return result
    }
}

public enum TrackerEvent: RawRepresentable {
    case started
    case stopped
    case completed
    case empty

    public var rawValue: Int {
        switch self {
        case .started: 0
        case .completed: 1
        case .stopped: 3
        case .empty: 0
        }
    }

    public init?(rawValue: Int) {
        switch rawValue {
        case 0: self = .started
        case 1: self = .completed
        case 3: self = .stopped
        default: self = .empty
        }
    }
}

private func httpEventString(_ event: TrackerEvent) -> String {
    switch event {
    case .started: "started"
    case .stopped: "stopped"
    case .completed: "completed"
    case .empty: ""
    }
}

public struct TrackerResponse: Sendable {
    public let interval: Int
    public let seeders: Int
    public let leechers: Int
    public let peers: [PeerInfo]
}

public struct PeerInfo: Sendable, Hashable {
    public let ip: String
    public let port: Int
    public let peerId: String?

    public var address: String {
        "\(ip):\(port)"
    }
}

public enum TrackerError: Error, LocalizedError {
    case invalidURL
    case requestFailed
    case invalidResponse
    case trackerFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid tracker URL"
        case .requestFailed: "Tracker request failed"
        case .invalidResponse: "Invalid tracker response"
        case .trackerFailure(let reason): "Tracker failure: \(reason)"
        }
    }
}
