import Foundation
import Network

// MARK: - Peer Wire Protocol

public enum WireMessage: Equatable, Sendable {
    case keepAlive
    case choke
    case unchoke
    case interested
    case notInterested
    case have(pieceIndex: UInt32)
    case bitfield(Data)
    case request(pieceIndex: UInt32, offset: UInt32, length: UInt32)
    case piece(pieceIndex: UInt32, offset: UInt32, block: Data)
    case cancel(pieceIndex: UInt32, offset: UInt32, length: UInt32)
    case port(port: UInt16)

    public func encode() -> Data {
        var data = Data()

        switch self {
        case .keepAlive:
            data.append(contentsOf: [0, 0, 0, 0])
        case .choke:
            data.append(contentsOf: [0, 0, 0, 1, 0])
        case .unchoke:
            data.append(contentsOf: [0, 0, 0, 1, 1])
        case .interested:
            data.append(contentsOf: [0, 0, 0, 1, 2])
        case .notInterested:
            data.append(contentsOf: [0, 0, 0, 1, 3])
        case .have(let pieceIndex):
            data.append(contentsOf: [0, 0, 0, 5, 4])
            data.append(contentsOf: pieceIndex.bigEndianBytes)
        case .bitfield(let field):
            let length = UInt32(1 + field.count)
            data.append(contentsOf: length.bigEndianBytes)
            data.append(5)
            data.append(field)
        case .request(let piece, let offset, let length):
            data.append(contentsOf: [0, 0, 0, 13, 6])
            data.append(contentsOf: piece.bigEndianBytes)
            data.append(contentsOf: offset.bigEndianBytes)
            data.append(contentsOf: length.bigEndianBytes)
        case .piece(let piece, let offset, let block):
            let length = UInt32(1 + 4 + 4 + block.count)
            data.append(contentsOf: length.bigEndianBytes)
            data.append(7)
            data.append(contentsOf: piece.bigEndianBytes)
            data.append(contentsOf: offset.bigEndianBytes)
            data.append(block)
        case .cancel(let piece, let offset, let length):
            data.append(contentsOf: [0, 0, 0, 13, 8])
            data.append(contentsOf: piece.bigEndianBytes)
            data.append(contentsOf: offset.bigEndianBytes)
            data.append(contentsOf: length.bigEndianBytes)
        case .port(let port):
            data.append(contentsOf: [0, 0, 0, 3, 9])
            data.append(contentsOf: port.bigEndianBytes)
        }

        return data
    }

    public static func decode(_ data: Data) -> WireMessage? {
        let cleanData = Data(data)
        guard cleanData.count >= 4 else { return nil }

        let length = UInt32(cleanData[0]) << 24 | UInt32(cleanData[1]) << 16 | UInt32(cleanData[2]) << 8 | UInt32(cleanData[3])

        if length == 0 {
            return .keepAlive
        }

        guard cleanData.count >= 5 else { return nil }
        let messageId = cleanData[4]

        switch messageId {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4:
            guard cleanData.count >= 9 else { return nil }
            let piece = UInt32(cleanData[5]) << 24 | UInt32(cleanData[6]) << 16 | UInt32(cleanData[7]) << 8 | UInt32(cleanData[8])
            return .have(pieceIndex: piece)
        case 5:
            return .bitfield(Data(cleanData[5...]))
        case 6:
            guard cleanData.count >= 17 else { return nil }
            let piece = UInt32(cleanData[5]) << 24 | UInt32(cleanData[6]) << 16 | UInt32(cleanData[7]) << 8 | UInt32(cleanData[8])
            let offset = UInt32(cleanData[9]) << 24 | UInt32(cleanData[10]) << 16 | UInt32(cleanData[11]) << 8 | UInt32(cleanData[12])
            let length = UInt32(cleanData[13]) << 24 | UInt32(cleanData[14]) << 16 | UInt32(cleanData[15]) << 8 | UInt32(cleanData[16])
            return .request(pieceIndex: piece, offset: offset, length: length)
        case 7:
            guard cleanData.count >= 13 else { return nil }
            let piece = UInt32(cleanData[5]) << 24 | UInt32(cleanData[6]) << 16 | UInt32(cleanData[7]) << 8 | UInt32(cleanData[8])
            let offset = UInt32(cleanData[9]) << 24 | UInt32(cleanData[10]) << 16 | UInt32(cleanData[11]) << 8 | UInt32(cleanData[12])
            return .piece(pieceIndex: piece, offset: offset, block: Data(cleanData[13...]))
        case 8:
            guard cleanData.count >= 17 else { return nil }
            let piece = UInt32(cleanData[5]) << 24 | UInt32(cleanData[6]) << 16 | UInt32(cleanData[7]) << 8 | UInt32(cleanData[8])
            let offset = UInt32(cleanData[9]) << 24 | UInt32(cleanData[10]) << 16 | UInt32(cleanData[11]) << 8 | UInt32(cleanData[12])
            let length = UInt32(cleanData[13]) << 24 | UInt32(cleanData[14]) << 16 | UInt32(cleanData[15]) << 8 | UInt32(cleanData[16])
            return .cancel(pieceIndex: piece, offset: offset, length: length)
        case 9:
            guard cleanData.count >= 7 else { return nil }
            let port = UInt16(cleanData[5]) << 8 | UInt16(cleanData[6])
            return .port(port: port)
        default:
            return nil
        }
    }
}

// MARK: - Peer Connection

@MainActor
public final class PeerConnection: ObservableObject {
    public enum State: Equatable {
        case connecting
        case handshaking
        case connected
        case choked
        case unchoked
        case downloading
        case disconnected
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.connecting, .connecting), (.handshaking, .handshaking),
                 (.connected, .connected), (.choked, .choked),
                 (.unchoked, .unchoked), (.downloading, .downloading),
                 (.disconnected, .disconnected):
                return true
            case (.error(let l), .error(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    @Published public private(set) var state: State = .connecting
    @Published public var downloadSpeed: Double = 0
    @Published public var piecesReceived: Int = 0

    public let peerInfo: PeerInfo
    public let peerId: String

    public var isActive: Bool {
        switch state {
        case .connected, .choked, .unchoked, .downloading, .handshaking:
            return true
        default:
            return false
        }
    }

    private var connection: NWConnection?
    private var buffer = Data()
    private var isChoked = true
    private var peerBitfield: Data = Data()
    private var pieceManager: PieceManager?
    private var onPieceReceived: ((UInt32, UInt32, Data) async -> Void)?
    private var outstandingRequests: Set<BlockRequest> = []
    private var requestSentAt: [BlockRequest: Date] = [:]

    private let maxOutstanding = 8
    private let requestTimeout: TimeInterval = 20

    public init(peerInfo: PeerInfo, connectionPeerId: String) {
        self.peerInfo = peerInfo
        self.peerId = connectionPeerId
    }

    public func connect(
        infoHash: String,
        pieceManager: PieceManager,
        onPieceReceived: @escaping (UInt32, UInt32, Data) async -> Void
    ) async {
        self.pieceManager = pieceManager
        self.onPieceReceived = onPieceReceived
        state = .connecting

        guard peerInfo.port > 0, peerInfo.port < 65536,
              let port = NWEndpoint.Port(rawValue: UInt16(peerInfo.port)) else {
            state = .error("Invalid peer address")
            return
        }

        TorrentLog.debug("[PeerConnection] Connecting to \(peerInfo.ip):\(peerInfo.port)")
        let host = NWEndpoint.Host(peerInfo.ip)

        let parameters = NWParameters.tcp
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 8
        parameters.defaultProtocolStack.transportProtocol = tcpOptions

        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection

        let connected = await waitForTCPReady(connection: connection)
        guard connected else { return }

        state = .handshaking
        await sendHandshake(infoHash: infoHash)
        await receiveHandshake(infoHash: infoHash)

        guard case .connected = state else { return }

        await sendInterested()
        await startReceiving()
    }

    public func disconnect() {
        recycleOutstandingRequests()
        connection?.cancel()
        state = .disconnected
    }

    public func expireStalledRequests() async {
        guard !outstandingRequests.isEmpty else { return }
        let now = Date.now
        let stale = outstandingRequests.filter { request in
            guard let sent = requestSentAt[request] else { return true }
            return now.timeIntervalSince(sent) > requestTimeout
        }
        guard !stale.isEmpty else { return }
        for request in stale {
            outstandingRequests.remove(request)
            requestSentAt.removeValue(forKey: request)
        }
        await pieceManager?.recycleRequests(Array(stale))
        if !isChoked {
            await requestPieces()
        }
    }

    private func waitForTCPReady(connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = PeerConnectionGate(continuation: continuation)

            connection.stateUpdateHandler = { [weak self] nwState in
                Task { @MainActor in
                    guard let self else {
                        gate.finishOnce()
                        return
                    }
                    switch nwState {
                    case .ready:
                        if self.state == .connecting {
                            self.state = .connected
                        }
                        gate.finishOnce()
                    case .failed(let error):
                        self.state = .error(error.localizedDescription)
                        self.recycleOutstandingRequests()
                        gate.finishOnce()
                    case .waiting:
                        TorrentLog.debug("[PeerConnection] Waiting on \(self.peerInfo.ip):\(self.peerInfo.port)")
                    case .cancelled:
                        self.state = .disconnected
                        self.recycleOutstandingRequests()
                        gate.finishOnce()
                    default:
                        break
                    }
                }
            }

            connection.start(queue: .main)

            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
                Task { @MainActor in
                    guard let self, !gate.hasFinished else { return }
                    if self.state == .connecting {
                        self.state = .error("Connection timeout")
                        self.recycleOutstandingRequests()
                        connection.cancel()
                    }
                    gate.finishOnce()
                }
            }
        }

        if case .connected = state { return true }
        return false
    }

    private func recycleOutstandingRequests() {
        guard !outstandingRequests.isEmpty else { return }
        let requestsToRecycle = Array(outstandingRequests)
        outstandingRequests.removeAll()
        requestSentAt.removeAll()
        Task { [pieceManager] in
            await pieceManager?.recycleRequests(requestsToRecycle)
        }
    }

    private func sendHandshake(infoHash: String) async {
        var handshake = Data()
        handshake.append(19)
        handshake.append(contentsOf: "BitTorrent protocol".utf8)
        handshake.append(contentsOf: [UInt8](repeating: 0, count: 8))
        handshake.append(contentsOf: hexToData(infoHash))
        handshake.append(BitTorrentPeerID.data(for: peerId))
        connection?.send(content: handshake, completion: .contentProcessed { _ in })
    }

    private func receiveHandshake(infoHash: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 128) { data, _, _, error in
                Task { @MainActor in
                    defer { continuation.resume() }

                    if let error {
                        self.state = .error(error.localizedDescription)
                        return
                    }

                    guard let data, data.count >= 68 else {
                        self.state = .error("Invalid handshake")
                        return
                    }

                    let pstrLength = Int(data[0])
                    let pstr = String(data: data[1..<(1 + pstrLength)], encoding: .utf8)
                    guard pstr == "BitTorrent protocol" else {
                        self.state = .error("Invalid protocol string")
                        return
                    }

                    let peerInfoHashStart = 1 + pstrLength + 8
                    let peerInfoHashEnd = peerInfoHashStart + 20
                    let peerHash = data[peerInfoHashStart..<peerInfoHashEnd]

                    if peerHash.hexString != infoHash.lowercased() {
                        self.state = .error("Info hash mismatch")
                        return
                    }

                    self.state = .connected
                }
            }
        }
    }

    private func sendInterested() async {
        connection?.send(content: WireMessage.interested.encode(), completion: .contentProcessed { _ in })
    }

    private func startReceiving() async {
        await receiveMessages()
    }

    private func receiveMessages() async {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.state = .error(error.localizedDescription)
                    self.recycleOutstandingRequests()
                    return
                }

                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    while let message = self.parseNextMessage() {
                        await self.handleMessage(message)
                    }
                }

                if isComplete {
                    self.state = .disconnected
                    self.recycleOutstandingRequests()
                    return
                }

                await self.receiveMessages()
            }
        }
    }

    private func parseNextMessage() -> WireMessage? {
        guard buffer.count >= 4 else { return nil }

        let start = buffer.startIndex
        let length = UInt32(buffer[start]) << 24 | UInt32(buffer[start + 1]) << 16
            | UInt32(buffer[start + 2]) << 8 | UInt32(buffer[start + 3])

        if length == 0 {
            buffer.removeFirst(4)
            return .keepAlive
        }

        let totalLength = 4 + Int(length)
        guard buffer.count >= totalLength else { return nil }

        let messageData = Data(buffer[start..<(start + totalLength)])
        buffer.removeFirst(totalLength)
        return WireMessage.decode(messageData)
    }

    private func handleMessage(_ message: WireMessage) async {
        switch message {
        case .choke:
            isChoked = true
            state = .choked
            recycleOutstandingRequests()
        case .unchoke:
            isChoked = false
            state = .unchoked
            await requestPieces()
        case .interested:
            break
        case .notInterested:
            break
        case .have(let pieceIndex):
            setPeerHasPiece(pieceIndex)
            if !isChoked {
                await requestPieces()
            }
        case .bitfield(let field):
            peerBitfield = field
            if !isChoked {
                await requestPieces()
            }
        case .piece(let pieceIndex, let offset, let block):
            await handlePiece(pieceIndex: pieceIndex, offset: offset, block: block)
        case .request, .cancel, .port, .keepAlive:
            break
        }
    }

    private func setPeerHasPiece(_ pieceIndex: UInt32) {
        let byteIndex = Int(pieceIndex / 8)
        let bitIndex = Int(pieceIndex % 8)
        if peerBitfield.count <= byteIndex {
            peerBitfield.append(contentsOf: [UInt8](repeating: 0, count: byteIndex - peerBitfield.count + 1))
        }
        peerBitfield[byteIndex] |= (1 << (7 - bitIndex))
    }

    private func requestPieces() async {
        guard let pieceManager, !isChoked else { return }

        let availableSlots = maxOutstanding - outstandingRequests.count
        guard availableSlots > 0 else { return }

        state = .downloading

        for _ in 0..<availableSlots {
            guard let request = await pieceManager.getNextRequest(peerBitfield: peerBitfield) else { break }

            outstandingRequests.insert(request)
            requestSentAt[request] = Date.now

            let message = WireMessage.request(
                pieceIndex: request.pieceIndex,
                offset: request.offset,
                length: request.length
            )
            connection?.send(content: message.encode(), completion: .contentProcessed { _ in })
        }
    }

    private func handlePiece(pieceIndex: UInt32, offset: UInt32, block: Data) async {
        let completed = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: 0)
        outstandingRequests.remove(completed)
        requestSentAt.removeValue(forKey: completed)
        piecesReceived += 1

        if let callback = onPieceReceived {
            await callback(pieceIndex, offset, block)
        }
        await requestPieces()
    }

    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let byteString = hex[index..<nextIndex]
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private final class PeerConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasFinished = false

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func finishOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFinished, let continuation else { return }
        hasFinished = true
        self.continuation = nil
        continuation.resume()
    }
}
