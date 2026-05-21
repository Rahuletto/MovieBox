import Foundation
import Network

public struct DHTNode: Hashable, Sendable {
    public let nodeId: Data
    public let address: String
    public let port: Int

    public init(nodeId: Data, address: String, port: Int) {
        self.nodeId = nodeId
        self.address = address
        self.port = port
    }

    var cacheKey: String { "\(address):\(port)" }
}

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
    private var peerTokens: [String: Data] = [:]
    private let networkQueue = DispatchQueue(label: "moviebox.kademlia.dht")

    public init(nodeId: Data? = nil) {
        self.nodeId = nodeId ?? Self.generateNodeId()
        setupBootstrapNodes()
    }

    public func start(port: Int = 6881) async throws {
        state = .bootstrapping

        let parameters = NWParameters.udp
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw DHTError.failedToStart
        }
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

        listener?.start(queue: networkQueue)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            networkQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                Task { @MainActor in
                    if self?.listener != nil {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: DHTError.failedToStart)
                    }
                }
            }
        }
    }

    public func stop() {
        state = .stopped
        listener?.cancel()
        listener = nil
        peerTokens.removeAll()
    }

    public func findPeers(infoHash: String) async -> [PeerInfo] {
        guard state == .running else { return [] }

        let infoHashData = HexEncoding.data(fromHex: infoHash)
        guard infoHashData.count == 20 else { return [] }

        var closestNodes = findClosestNodes(to: infoHashData, count: bucketSize)
        var queried: Set<Data> = []
        var peers: [PeerInfo] = []
        var seenPeers = Set<String>()

        for _ in 0..<4 {
            let toQuery = closestNodes.filter { !queried.contains($0.nodeId) }.prefix(bucketSize)
            guard !toQuery.isEmpty else { break }

            var newNodes: [DHTNode] = []
            for node in toQuery {
                queried.insert(node.nodeId)
                if let response = await sendGetPeers(to: node, infoHash: infoHashData) {
                    for peer in response.peers {
                        let key = "\(peer.ip):\(peer.port)"
                        if seenPeers.insert(key).inserted {
                            peers.append(peer)
                        }
                    }
                    newNodes.append(contentsOf: response.nodes)
                }
            }
            closestNodes = mergeNodes(closestNodes + newNodes, target: infoHashData, count: bucketSize)
            if !peers.isEmpty { break }
        }

        return peers
    }

    public func announce(infoHash: String, port: Int) async {
        guard state == .running else { return }

        let infoHashData = HexEncoding.data(fromHex: infoHash)
        guard infoHashData.count == 20 else { return }

        var closestNodes = findClosestNodes(to: infoHashData, count: bucketSize)
        var queried: Set<Data> = []

        for _ in 0..<4 {
            let toQuery = closestNodes.filter { !queried.contains($0.nodeId) }.prefix(bucketSize)
            guard !toQuery.isEmpty else { break }

            var newNodes: [DHTNode] = []
            for node in toQuery {
                queried.insert(node.nodeId)
                if let response = await sendGetPeers(to: node, infoHash: infoHashData) {
                    newNodes.append(contentsOf: response.nodes)
                    if let token = response.token {
                        await sendAnnouncePeer(to: node, infoHash: infoHashData, port: port, token: token)
                    }
                }
            }
            closestNodes = mergeNodes(closestNodes + newNodes, target: infoHashData, count: bucketSize)
        }
    }

    private func bootstrap() async {
        for node in bootstrapNodes {
            if let response = await sendFindNode(to: node, target: nodeId) {
                ingestNodes(response.nodes)
            }
        }
        routingTable = Array(routingTable.prefix(200))
    }

    private func ingestNodes(_ nodes: [DHTNode]) {
        for newNode in nodes where newNode.nodeId.count == 20 {
            if !routingTable.contains(where: { $0.nodeId == newNode.nodeId }) {
                routingTable.append(newNode)
            }
        }
        // Cap routing table to prevent unbounded growth during peer discovery.
        if routingTable.count > 200 {
            routingTable = Array(routingTable.prefix(200))
        }
    }

    private func sendFindNode(to node: DHTNode, target: Data) async -> DHTResponse? {
        await sendQuery(to: node, method: "find_node", args: ["id": nodeId, "target": target])
    }

    private func sendGetPeers(to node: DHTNode, infoHash: Data) async -> DHTResponse? {
        await sendQuery(to: node, method: "get_peers", args: ["id": nodeId, "info_hash": infoHash])
    }

    private func sendAnnouncePeer(to node: DHTNode, infoHash: Data, port: Int, token: Data) async {
        _ = await sendQuery(
            to: node,
            method: "announce_peer",
            args: [
                "id": nodeId,
                "info_hash": infoHash,
                "port": Int64(port),
                "token": token,
                "implied_port": Int64(0),
            ]
        )
    }

    private func sendQuery(to node: DHTNode, method: String, args: [String: Any]) async -> DHTResponse? {
        guard let connection = try? createConnection(to: node) else { return nil }

        let transactionId = randomTransactionId()
        let message = makeMessage(transactionId: transactionId, method: method, args: args)
        let data = BencodeParser.encode(message)

        // Use a class-based gate so the continuation is resumed exactly once
        // even if both the receive callback and the timeout fire concurrently.
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            private var cont: CheckedContinuation<DHTResponse?, Never>?
            init(_ c: CheckedContinuation<DHTResponse?, Never>) { cont = c }
            func finish(_ value: DHTResponse?) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont?.resume(returning: value)
                cont = nil
            }
        }

        let result: DHTResponse? = await withCheckedContinuation { continuation in
            let gate = Gate(continuation)
            connection.send(content: data, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { responseData, _, _, _ in
                Task { @MainActor [weak self] in
                    defer { connection.cancel() }
                    guard let responseData,
                          let bencode = try? BencodeParser.parse(responseData),
                          let response = DHTResponse(from: bencode) else {
                        gate.finish(nil)
                        return
                    }
                    if let token = response.token {
                        self?.peerTokens[node.cacheKey] = token
                    }
                    gate.finish(response)
                }
            }
            // Timeout: cancel the connection and resume after 3 seconds.
            Task {
                try? await Task.sleep(for: .seconds(3))
                connection.cancel()
                gate.finish(nil)
            }
        }
        return result
    }

    private func createConnection(to node: DHTNode) throws -> NWConnection {
        let host = NWEndpoint.Host(node.address)
        guard let port = NWEndpoint.Port(rawValue: UInt16(node.port)) else {
            throw DHTError.invalidNode
        }
        let connection = NWConnection(host: host, port: port, using: .udp)
        connection.start(queue: networkQueue)
        return connection
    }

    private func handleIncoming(_ connection: NWConnection) async {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self, let data,
                      let bencode = try? BencodeParser.parse(data),
                      let dict = bencode.dictionary else { return }

                guard let y = dict["y"]?.string else { return }

                if y == "q", let method = dict["q"]?.string {
                    let transaction = self.bencodeBinary(dict["t"])
                    let response = self.handleQuery(method: method, args: dict["a"]?.dictionary ?? [:], transaction: transaction)
                    let responseData = BencodeParser.encode(response)
                    connection.send(content: responseData, completion: .contentProcessed { _ in })
                }
            }
        }
    }

    private func handleQuery(method: String, args: [String: BencodeValue], transaction: Data) -> BencodeValue {
        var responseArgs: [String: BencodeValue] = ["id": .string(nodeId)]

        switch method {
        case "find_node", "get_peers":
            let targetFromNode = bencodeBinary(args["target"])
            let targetData = targetFromNode.isEmpty ? bencodeBinary(args["info_hash"]) : targetFromNode
            let closest = findClosestNodes(to: targetData, count: bucketSize)
            responseArgs["nodes"] = .string(DHTCodec.encodeCompactNodes(closest))
            if method == "get_peers" {
                responseArgs["token"] = .string(randomTransactionId())
            }
        case "announce_peer":
            break
        default:
            break
        }

        return .dictionary([
            "t": .string(transaction),
            "y": .string(Data("r".utf8)),
            "r": .dictionary(responseArgs),
        ])
    }

    private func findClosestNodes(to target: Data, count: Int) -> [DHTNode] {
        routingTable.sorted { a, b in
            DHTCodec.compareDistance(a.nodeId, b.nodeId, to: target)
        }.prefix(count).map { $0 }
    }

    private func mergeNodes(_ nodes: [DHTNode], target: Data, count: Int) -> [DHTNode] {
        var unique: [DHTNode] = []
        var seen: Set<Data> = []
        for node in nodes {
            guard node.nodeId.count == 20, !seen.contains(node.nodeId) else { continue }
            seen.insert(node.nodeId)
            unique.append(node)
        }
        return unique.sorted { a, b in
            DHTCodec.compareDistance(a.nodeId, b.nodeId, to: target)
        }.prefix(count).map { $0 }
    }

    private func makeMessage(transactionId: Data, method: String, args: [String: Any]) -> BencodeValue {
        var dict: [String: BencodeValue] = [
            "t": .string(transactionId),
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

    private func randomTransactionId() -> Data {
        var bytes = Data(count: 2)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 2, base)
        }
        return bytes
    }

    private static func generateNodeId() -> Data {
        var bytes = Data(count: 20)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 20, base)
        }
        return bytes
    }

    private func setupBootstrapNodes() {
        bootstrapNodes = [
            DHTNode(nodeId: Data(repeating: 0, count: 20), address: "router.bittorrent.com", port: 6881),
            DHTNode(nodeId: Data(repeating: 0, count: 20), address: "router.utorrent.com", port: 6881),
            DHTNode(nodeId: Data(repeating: 0, count: 20), address: "dht.transmissionbt.com", port: 6881),
        ]
    }

    private func bencodeBinary(_ value: BencodeValue?) -> Data {
        guard let value, case .string(let data) = value else { return Data() }
        return data
    }
}

struct DHTResponse {
    let nodes: [DHTNode]
    let peers: [PeerInfo]
    let token: Data?

    init?(from bencode: BencodeValue) {
        guard let dict = bencode.dictionary,
              let responseData = dict["r"]?.dictionary else { return nil }

        if case .string(let nodesData) = responseData["nodes"] {
            nodes = DHTCodec.decodeCompactNodes(nodesData)
        } else {
            nodes = []
        }

        if case .string(let peersData) = responseData["values"] {
            peers = DHTCodec.decodeCompactPeers(peersData)
        } else {
            peers = []
        }

        if case .string(let tokenData) = responseData["token"] {
            token = tokenData
        } else {
            token = nil
        }
    }
}

public enum DHTError: Error, LocalizedError {
    case failedToStart
    case invalidNode
    case queryTimeout

    public var errorDescription: String? {
        switch self {
        case .failedToStart: return "Failed to start DHT listener"
        case .invalidNode: return "Invalid DHT node"
        case .queryTimeout: return "DHT query timed out"
        }
    }
}
