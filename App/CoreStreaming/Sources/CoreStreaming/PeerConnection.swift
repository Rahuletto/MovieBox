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
            let field = cleanData[5...]
            return .bitfield(Data(field))
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
            let block = cleanData[13...]
            return .piece(pieceIndex: piece, offset: offset, block: Data(block))
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

    private var connection: NWConnection?
    private var buffer = Data()
    private var isChoked = true
    private var peerBitfield: Data = Data()
    private var pieceManager: PieceManager?
    private var onPieceReceived: ((UInt32, UInt32, Data) async -> Void)?
    private var bytesDownloaded: Int64 = 0
    private var downloadStartTime: Date?
    private var outstandingRequests: Set<BlockRequest> = []

    public init(peerInfo: PeerInfo, connectionPeerId: String) {
        self.peerInfo = peerInfo
        self.peerId = connectionPeerId
    }

    public func connect(infoHash: String, pieceManager: PieceManager, onPieceReceived: @escaping (UInt32, UInt32, Data) async -> Void) async {
        self.pieceManager = pieceManager
        self.onPieceReceived = onPieceReceived
        downloadStartTime = Date.now
        state = .connecting

        guard peerInfo.port > 0 && peerInfo.port < 65536,
              let port = NWEndpoint.Port(rawValue: UInt16(peerInfo.port)) else {
            state = .error("Invalid peer address")
            NSLog("[PeerConnection] ❌ Invalid peer port for \(peerInfo.ip):\(peerInfo.port)")
            return
        }

        NSLog("[PeerConnection] 🌐 Attempting to connect to peer \(peerInfo.ip):\(peerInfo.port)...")
        let host = NWEndpoint.Host(peerInfo.ip)

        let parameters = NWParameters.tcp
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 5
        parameters.defaultProtocolStack.transportProtocol = tcpOptions

        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection

        await withCheckedContinuation { continuation in
            let gate = PeerConnectionGate(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { [weak self] nwState in
                Task { @MainActor in
                    guard let self else {
                        gate.finishWithCancellation()
                        return
                    }
                    self.handleConnectionState(nwState)
                    switch nwState {
                    case .ready:
                        NSLog("[PeerConnection] 🔌 Connection established (ready) with \(self.peerInfo.ip):\(self.peerInfo.port)")
                        gate.finish()
                    case .failed(let error):
                        NSLog("[PeerConnection] ❌ Connection failed with \(self.peerInfo.ip):\(self.peerInfo.port) - \(error.localizedDescription)")
                        self.state = .error(error.localizedDescription)
                        self.recycleOutstandingRequests()
                        gate.finish()
                    case .waiting(let error):
                        NSLog("[PeerConnection] ⏳ Connection waiting (unreachable) for \(self.peerInfo.ip):\(self.peerInfo.port) - \(error.localizedDescription)")
                        self.state = .error("Connection waiting: \(error.localizedDescription)")
                        self.recycleOutstandingRequests()
                        gate.finishWithCancellation()
                    case .cancelled:
                        NSLog("[PeerConnection] 🚫 Connection cancelled with \(self.peerInfo.ip):\(self.peerInfo.port)")
                        self.state = .disconnected
                        self.recycleOutstandingRequests()
                        gate.finish()
                    default:
                        break
                    }
                }
            }

            connection.start(queue: .main)

            // Explicit safety timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                Task { @MainActor in
                    if self.state == .connecting {
                        NSLog("[PeerConnection] ⏱️ Connection timeout (5.0s elapsed) for \(self.peerInfo.ip):\(self.peerInfo.port)")
                        self.state = .error("Connection timeout")
                    }
                    gate.finishWithCancellation()
                }
            }
        }

        guard case .connected = state else {
            NSLog("[PeerConnection] ❌ Connection aborted to \(peerInfo.ip):\(peerInfo.port) - State is not connected")
            return
        }

        NSLog("[PeerConnection] 🤝 Starting BitTorrent handshake with \(peerInfo.ip):\(peerInfo.port)...")
        state = .handshaking
        await sendHandshake(infoHash: infoHash)
        await receiveHandshake(infoHash: infoHash)

        guard case .connected = state else {
            NSLog("[PeerConnection] ❌ Handshake aborted with \(peerInfo.ip):\(peerInfo.port) - State is not connected")
            return
        }

        NSLog("[PeerConnection] 💖 Handshake successful! Sending INTERESTED message to \(peerInfo.ip):\(peerInfo.port)")
        await sendInterested()
        await startReceiving()
    }

    public func disconnect() {
        recycleOutstandingRequests()
        connection?.cancel()
        state = .disconnected
    }

    private func recycleOutstandingRequests() {
        guard !outstandingRequests.isEmpty else { return }
        let requestsToRecycle = Array(outstandingRequests)
        outstandingRequests.removeAll()
        NSLog("[PeerConnection] ♻️ Recycling \(requestsToRecycle.count) outstanding requests from \(peerInfo.ip):\(peerInfo.port)")
        Task { [pieceManager] in
            await pieceManager?.recycleRequests(requestsToRecycle)
        }
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if self.state == .connecting {
                self.state = .connected
            }
        case .failed(let error):
            self.state = .error(error.localizedDescription)
        case .cancelled:
            self.state = .disconnected
        default:
            break
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
        await withCheckedContinuation { continuation in
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 68) { data, _, _, error in
                Task { @MainActor in
                    if let error {
                        self.state = .error(error.localizedDescription)
                        continuation.resume()
                        return
                    }

                    guard let data, data.count >= 68 else {
                        self.state = .error("Invalid handshake")
                        continuation.resume()
                        return
                    }

                    let pstrLength = Int(data[0])
                    let pstr = String(data: data[1..<(1 + pstrLength)], encoding: .utf8)

                    guard pstr == "BitTorrent protocol" else {
                        self.state = .error("Invalid protocol string")
                        continuation.resume()
                        return
                    }

                    let peerInfoHashStart = 1 + pstrLength + 8
                    let peerInfoHashEnd = peerInfoHashStart + 20
                    let peerHash = data[peerInfoHashStart..<peerInfoHashEnd]

                    if peerHash.hexString != infoHash {
                        self.state = .error("Info hash mismatch")
                        continuation.resume()
                        return
                    }

                    self.state = .connected
                    continuation.resume()
                }
            }
        }
    }

    private func sendInterested() async {
        let message = WireMessage.interested.encode()
        connection?.send(content: message, completion: .contentProcessed { _ in })
    }

    private func startReceiving() async {
        await receiveMessages()
    }

    private func receiveMessages() async {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let strongSelf = self else { return }

                if let error {
                    strongSelf.state = .error(error.localizedDescription)
                    return
                }

                if let data, !data.isEmpty {
                    strongSelf.buffer.append(data)
                    while let message = strongSelf.parseNextMessage() {
                        await strongSelf.handleMessage(message)
                    }
                }

                if isComplete {
                    strongSelf.state = .disconnected
                    return
                }

                await strongSelf.receiveMessages()
            }
        }
    }

    private func parseNextMessage() -> WireMessage? {
        guard buffer.count >= 4 else { return nil }

        let start = buffer.startIndex
        let length = UInt32(buffer[start]) << 24 | UInt32(buffer[start + 1]) << 16 | UInt32(buffer[start + 2]) << 8 | UInt32(buffer[start + 3])

        if length == 0 {
            buffer.removeFirst(4)
            return .keepAlive
        }

        let totalLength = 4 + Int(length)
        guard buffer.count >= totalLength else { return nil }

        let messageEnd = start + totalLength
        let messageData = Data(buffer[start..<messageEnd])
        buffer.removeFirst(totalLength)

        return WireMessage.decode(messageData)
    }

    private func handleMessage(_ message: WireMessage) async {
        switch message {
        case .choke:
            NSLog("[PeerConnection] 🔴 \(peerInfo.ip):\(peerInfo.port) sent CHOKE (downloads choked)")
            isChoked = true
            state = .choked
            recycleOutstandingRequests()
        case .unchoke:
            NSLog("[PeerConnection] 🟢 \(peerInfo.ip):\(peerInfo.port) sent UNCHOKE (downloads unchoked!)")
            isChoked = false
            state = .unchoked
            await requestPieces()
        case .interested:
            NSLog("[PeerConnection] 📥 \(peerInfo.ip):\(peerInfo.port) is INTERESTED")
            let message = WireMessage.unchoke.encode()
            connection?.send(content: message, completion: .contentProcessed { _ in })
        case .notInterested:
            NSLog("[PeerConnection] 📥 \(peerInfo.ip):\(peerInfo.port) is NOT INTERESTED")
            break
        case .have(let pieceIndex):
            NSLog("[PeerConnection] 📰 \(peerInfo.ip):\(peerInfo.port) has piece \(pieceIndex)")
            setPeerHasPiece(pieceIndex)
            if !isChoked {
                await requestPieces()
            }
        case .bitfield(let field):
            NSLog("[PeerConnection] 📊 \(peerInfo.ip):\(peerInfo.port) sent BITFIELD (size: \(field.count) bytes)")
            peerBitfield = field
            if !isChoked {
                await requestPieces()
            }
        case .piece(let pieceIndex, let offset, let block):
            NSLog("[PeerConnection] 📥 Received block: piece \(pieceIndex), offset \(offset), length \(block.count) bytes from \(peerInfo.ip):\(peerInfo.port)")
            await handlePiece(pieceIndex: pieceIndex, offset: offset, block: block)
        case .request(let pieceIndex, let offset, let length):
            NSLog("[PeerConnection] 📤 Peer requested block: piece \(pieceIndex), offset \(offset), length \(length) from us")
        case .cancel, .port, .keepAlive:
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

    private func peerHasPiece(_ pieceIndex: UInt32) -> Bool {
        let byteIndex = Int(pieceIndex / 8)
        let bitIndex = Int(pieceIndex % 8)
        guard byteIndex < peerBitfield.count else { return false }
        return (peerBitfield[byteIndex] & (1 << (7 - bitIndex))) != 0
    }

    private func requestPieces() async {
        guard let pieceManager, !isChoked else { return }

        state = .downloading

        for _ in 0..<8 {
            guard let request = await pieceManager.getNextRequest(peerBitfield: peerBitfield) else { break }

            outstandingRequests.insert(request)
            NSLog("[PeerConnection] 📤 Requesting block: piece \(request.pieceIndex), offset \(request.offset), length \(request.length) from \(peerInfo.ip):\(peerInfo.port)")
            let message = WireMessage.request(
                pieceIndex: request.pieceIndex,
                offset: request.offset,
                length: request.length
            )
            connection?.send(content: message.encode(), completion: .contentProcessed { _ in })
        }
    }

    private func handlePiece(pieceIndex: UInt32, offset: UInt32, block: Data) async {
        bytesDownloaded += Int64(block.count)
        piecesReceived += 1
        updateDownloadSpeed()

        let request = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: UInt32(block.count))
        outstandingRequests.remove(request)

        if let callback = onPieceReceived {
            await callback(pieceIndex, offset, block)
        }
        await requestPieces()
    }

    private func updateDownloadSpeed() {
        guard let startTime = downloadStartTime else { return }
        let elapsed = Date.now.timeIntervalSince(startTime)
        if elapsed > 0 {
            downloadSpeed = Double(bytesDownloaded) / elapsed
        }
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

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private final class PeerConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var connection: NWConnection?

    init(continuation: CheckedContinuation<Void, Never>, connection: NWConnection) {
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

    func finishWithCancellation() {
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
        continuation.resume()
    }
}
