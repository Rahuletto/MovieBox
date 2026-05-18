import Foundation
import Network

// MARK: - DHT Node

public struct DHTNode: Hashable, Sendable {
    public let nodeId: Data
    public let address: String
    public let port: Int

    public init(nodeId: Data, address: String, port: Int) {
        self.nodeId = nodeId
        self.address = address
        self.port = port
    }
}

// MARK: - Kademlia DHT

@MainActor
public final class KademliaDHT {
    public enum State: Equatable {
        case stopped
        case bootstrapping
        case running
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.stopped, .stopped), (.bootstrapping, .bootstrapping), (.running, .running): true
            case (.error(let l), .error(let r)): l == r
            default: false
            }
        }
    }

    public private(set) var state: State = .stopped
    public private(set) var routingTable: [DHTNode] = []

    private let nodeId: Data
    private var listener: NWListener?
    private let bucketSize = 20
    private var bootstrapNodes: [DHTNode] = []

    public init(nodeId: Data? = nil) {
        self.nodeId = nodeId ?? Self.generateNodeId()
        setupBootstrapNodes()
    }

    public func start(port: Int = 6881) async throws {
        state = .bootstrapping

        let parameters = NWParameters.udp
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port))!
        listener = try NWListener(using: parameters, on: nwPort)

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                await self?.handleIncoming(connection)
            }
        }

        listener?.stateUpdateHandler = { [weak self] nwState in
            Task { @MainActor [weak self] in
                switch nwState {
                case .ready:
                    self?.state = .running
                    await self?.bootstrap()
                case .failed(let error):
                    self?.state = .error(error.localizedDescription)
                default:
                    break
                }
            }
        }

        listener?.start(queue: .main)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.listener != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: DHTError.failedToStart)
                }
            }
        }
    }

    public func stop() {
        state = .stopped
        listener?.cancel()
        listener = nil
    }

    public func findPeers(infoHash: String) async -> [PeerInfo] {
        guard state == .running else { return [] }

        let targetId = hexToData(infoHash)
        var closestNodes = findClosestNodes(to: targetId, count: bucketSize)
        var queried: Set<Data> = []
        var peers: [PeerInfo] = []

        for _ in 0..<3 {
            let toQuery = closestNodes.filter { !queried.contains($0.nodeId) }.prefix(bucketSize)
            guard !toQuery.isEmpty else { break }

            var newNodes: [DHTNode] = []
            for node in toQuery {
                queried.insert(node.nodeId)
                if let response = await sendFindNode(to: node, target: targetId) {
                    peers.append(contentsOf: response.peers)
                    newNodes.append(contentsOf: response.nodes)
                }
            }
            closestNodes = mergeNodes(closestNodes + newNodes, target: targetId, count: bucketSize)
        }

        return peers
    }

    public func announce(infoHash: String, port: Int) async {
        guard state == .running else { return }

        let targetId = hexToData(infoHash)
        var closestNodes = findClosestNodes(to: targetId, count: bucketSize)
        var queried: Set<Data> = []

        for _ in 0..<3 {
            let toQuery = closestNodes.filter { !queried.contains($0.nodeId) }.prefix(bucketSize)
            guard !toQuery.isEmpty else { break }

            var newNodes: [DHTNode] = []
            for node in toQuery {
                queried.insert(node.nodeId)
                await sendAnnounce(to: node, target: targetId, port: port)
                if let response = await sendFindNode(to: node, target: targetId) {
                    newNodes.append(contentsOf: response.nodes)
                }
            }
            closestNodes = mergeNodes(closestNodes + newNodes, target: targetId, count: bucketSize)
        }
    }

    private func bootstrap() async {
        for node in bootstrapNodes {
            _ = await sendPing(to: node)
            if let response = await sendFindNode(to: node, target: nodeId) {
                for newNode in response.nodes where !routingTable.contains(where: { $0.nodeId == newNode.nodeId }) {
                    routingTable.append(newNode)
                }
            }
        }
        routingTable = Array(routingTable.prefix(200))
    }

    private func sendPing(to node: DHTNode) async -> Bool {
        guard let connection = try? createConnection(to: node) else { return false }
        let message = makeMessage(transactionId: "pi", method: "ping", args: ["id": nodeId])
        let data = BencodeParser.encode(message)
        connection.send(content: data, completion: .contentProcessed { _ in })
        return true
    }

    private func sendFindNode(to node: DHTNode, target: Data) async -> DHTResponse? {
        guard let connection = try? createConnection(to: node) else { return nil }

        let transactionId = "fn\(UUID().uuidString.prefix(2))"
        let message = makeMessage(transactionId: String(transactionId), method: "find_node", args: ["id": nodeId, "target": target])
        let data = BencodeParser.encode(message)

        return await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { responseData, _, _, _ in
                Task { @MainActor in
                    guard let responseData,
                          let bencode = try? BencodeParser.parse(responseData),
                          let response = DHTResponse(from: bencode) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: response)
                }
            }
        }
    }

    private func sendAnnounce(to node: DHTNode, target: Data, port: Int) async {
        guard let connection = try? createConnection(to: node) else { return }
        let message = makeMessage(transactionId: "an", method: "announce_peer", args: ["id": nodeId, "info_hash": target, "port": Int64(port), "implied_port": Int64(0)])
        let data = BencodeParser.encode(message)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func createConnection(to node: DHTNode) throws -> NWConnection {
        let host = NWEndpoint.Host(node.address)
        let port = NWEndpoint.Port(rawValue: UInt16(node.port))!
        let connection = NWConnection(host: host, port: port, using: .udp)
        connection.start(queue: .main)
        return connection
    }

    private func handleIncoming(_ connection: NWConnection) async {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self, let data,
                      let bencode = try? BencodeParser.parse(data),
                      let dict = bencode.dictionary else { return }

                guard let y = dict["y"]?.string else { return }

                if y == "q", let method = dict["q"]?.string {
                    let response = self.handleQuery(method: method, args: dict["a"]?.dictionary ?? [:])
                    let responseData = BencodeParser.encode(response)
                    connection.send(content: responseData, completion: .contentProcessed { _ in })
                }
            }
        }
    }

    private func handleQuery(method: String, args: [String: BencodeValue]) -> BencodeValue {
        var responseArgs: [String: BencodeValue] = ["id": .string(nodeId)]

        switch method {
        case "find_node":
            let targetData = args["target"]?.string.flatMap { Data($0.utf8) } ?? Data()
            let closest = findClosestNodes(to: targetData, count: bucketSize)
            let nodesData = encodeNodes(closest)
            responseArgs["nodes"] = .string(nodesData)
        case "announce_peer":
            if let infoHashData = args["info_hash"]?.string {
                TorrentLog.debug("DHT announce for \(infoHashData)")
            }
        default:
            break
        }

        var dict: [String: BencodeValue] = [
            "t": args["t"] ?? .string(Data()),
            "y": .string(Data("r".utf8)),
            "r": .dictionary(responseArgs)
        ]
        return .dictionary(dict)
    }

    private func findClosestNodes(to target: Data, count: Int) -> [DHTNode] {
        routingTable.sorted { a, b in
            xorDistance(a.nodeId, target) < xorDistance(b.nodeId, target)
        }.prefix(count).map { $0 }
    }

    private func mergeNodes(_ nodes: [DHTNode], target: Data, count: Int) -> [DHTNode] {
        var unique: [DHTNode] = []
        var seen: Set<Data> = []
        for node in nodes where !seen.contains(node.nodeId) {
            seen.insert(node.nodeId)
            unique.append(node)
        }
        return unique.sorted { a, b in
            xorDistance(a.nodeId, target) < xorDistance(b.nodeId, target)
        }.prefix(count).map { $0 }
    }

    private func xorDistance(_ a: Data, _ b: Data) -> String {
        let result = zip(a, b).map { $0 ^ $1 }
        return result.map { String(format: "%02x", $0) }.joined()
    }

    private func makeMessage(transactionId: String, method: String, args: [String: Any]) -> BencodeValue {
        var dict: [String: BencodeValue] = [
            "t": .string(Data(transactionId.utf8)),
            "y": .string(Data("q".utf8)),
            "q": .string(Data(method.utf8)),
        ]
        var bencodeArgs: [String: BencodeValue] = [:]
        for (key, value) in args {
            switch value {
            case let data as Data:
                bencodeArgs[key] = .string(data)
            case let string as String:
                bencodeArgs[key] = .string(Data(string.utf8))
            case let int as Int64:
                bencodeArgs[key] = .integer(int)
            case let int as Int:
                bencodeArgs[key] = .integer(Int64(int))
            default:
                break
            }
        }
        dict["a"] = .dictionary(bencodeArgs)
        return .dictionary(dict)
    }

    private func encodeNodes(_ nodes: [DHTNode]) -> Data {
        var data = Data()
        for node in nodes {
            data.append(node.nodeId)
            data.append(contentsOf: node.address.utf8)
            if node.address.split(separator: ".").count == 4 {
                while data.count < node.nodeId.count + 4 {
                    data.append(0)
                }
            }
            data.append(UInt8(node.port >> 8))
            data.append(UInt8(node.port & 0xFF))
        }
        return data
    }

    private static func generateNodeId() -> Data {
        var bytes = Data(count: 20)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 20, $0.baseAddress!) }
        return bytes
    }

    private func setupBootstrapNodes() {
        bootstrapNodes = [
            DHTNode(nodeId: Data(), address: "router.bittorrent.com", port: 6881),
            DHTNode(nodeId: Data(), address: "router.utorrent.com", port: 6881),
            DHTNode(nodeId: Data(), address: "dht.transmissionbt.com", port: 6881),
        ]
    }

    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteString = hex[index..<nextIndex]
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }
}

struct DHTResponse {
    let nodes: [DHTNode]
    let peers: [PeerInfo]

    init?(from bencode: BencodeValue) {
        guard let dict = bencode.dictionary,
              let responseData = dict["r"]?.dictionary else { return nil }

        var nodes: [DHTNode] = []
        if case .string(let nodesData) = responseData["nodes"] ?? .string(Data()) {
            var index = nodesData.startIndex
            while index + 26 <= nodesData.endIndex {
                let nodeId = Data(nodesData[index..<index + 20])
                let ip = "\(nodesData[index + 20]).\(nodesData[index + 21]).\(nodesData[index + 22]).\(nodesData[index + 23])"
                let port = (Int(nodesData[index + 24]) << 8) | Int(nodesData[index + 25])
                nodes.append(DHTNode(nodeId: nodeId, address: ip, port: port))
                index += 26
            }
        }

        var peers: [PeerInfo] = []
        if case .string(let peersData) = responseData["values"] ?? .string(Data()) {
            var index = peersData.startIndex
            while index + 6 <= peersData.endIndex {
                let ip = "\(peersData[index]).\(peersData[index + 1]).\(peersData[index + 2]).\(peersData[index + 3])"
                let port = (Int(peersData[index + 4]) << 8) | Int(peersData[index + 5])
                peers.append(PeerInfo(ip: ip, port: port, peerId: nil))
                index += 6
            }
        }

        self.nodes = nodes
        self.peers = peers
    }
}

public enum DHTError: Error, LocalizedError {
    case failedToStart
    case invalidNode
    case queryTimeout

    public var errorDescription: String? {
        switch self {
        case .failedToStart: "Failed to start DHT listener"
        case .invalidNode: "Invalid DHT node"
        case .queryTimeout: "DHT query timed out"
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
