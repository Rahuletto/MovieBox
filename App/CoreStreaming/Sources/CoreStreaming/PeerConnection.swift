import Foundation
import Network

// MARK: - Peer Wire Protocol

public enum WireMessage: Sendable {
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
        guard data.count >= 4 else { return nil }

        let length = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])

        if length == 0 {
            return .keepAlive
        }

        guard data.count >= 5 else { return nil }
        let messageId = data[4]

        switch messageId {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4:
            guard data.count >= 9 else { return nil }
            let piece = UInt32(data[5]) << 24 | UInt32(data[6]) << 16 | UInt32(data[7]) << 8 | UInt32(data[8])
            return .have(pieceIndex: piece)
        case 5:
            let field = data[5...]
            return .bitfield(Data(field))
        case 6:
            guard data.count >= 17 else { return nil }
            let piece = UInt32(data[5]) << 24 | UInt32(data[6]) << 16 | UInt32(data[7]) << 8 | UInt32(data[8])
            let offset = UInt32(data[9]) << 24 | UInt32(data[10]) << 16 | UInt32(data[11]) << 8 | UInt32(data[12])
            let length = UInt32(data[13]) << 24 | UInt32(data[14]) << 16 | UInt32(data[15]) << 8 | UInt32(data[16])
            return .request(pieceIndex: piece, offset: offset, length: length)
        case 7:
            guard data.count >= 13 else { return nil }
            let piece = UInt32(data[5]) << 24 | UInt32(data[6]) << 16 | UInt32(data[7]) << 8 | UInt32(data[8])
            let offset = UInt32(data[9]) << 24 | UInt32(data[10]) << 16 | UInt32(data[11]) << 8 | UInt32(data[12])
            let block = data[13...]
            return .piece(pieceIndex: piece, offset: offset, block: Data(block))
        case 8:
            guard data.count >= 17 else { return nil }
            let piece = UInt32(data[5]) << 24 | UInt32(data[6]) << 16 | UInt32(data[7]) << 8 | UInt32(data[8])
            let offset = UInt32(data[9]) << 24 | UInt32(data[10]) << 16 | UInt32(data[11]) << 8 | UInt32(data[12])
            let length = UInt32(data[13]) << 24 | UInt32(data[14]) << 16 | UInt32(data[15]) << 8 | UInt32(data[16])
            return .cancel(pieceIndex: piece, offset: offset, length: length)
        case 9:
            guard data.count >= 7 else { return nil }
            let port = UInt16(data[5]) << 8 | UInt16(data[6])
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
    private var onPieceReceived: ((UInt32, UInt32, Data) -> Void)?
    private var bytesDownloaded: Int64 = 0
    private var downloadStartTime: Date?

    public init(peerInfo: PeerInfo, connectionPeerId: String) {
        self.peerInfo = peerInfo
        self.peerId = connectionPeerId
    }

    public func connect(infoHash: String, pieceManager: PieceManager, onPieceReceived: @escaping (UInt32, UInt32, Data) -> Void) async {
        self.pieceManager = pieceManager
        self.onPieceReceived = onPieceReceived
        downloadStartTime = Date.now
        state = .connecting

        guard peerInfo.port > 0 && peerInfo.port < 65536,
              let port = NWEndpoint.Port(rawValue: UInt16(peerInfo.port)) else {
            state = .error("Invalid peer address")
            return
        }

        let host = NWEndpoint.Host(peerInfo.ip)

        let connection = NWConnection(host: host, port: port, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }

        connection.start(queue: .main)

        await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { [weak self] nwState in
                Task { @MainActor in
                    self?.handleConnectionState(nwState)
                    if case .ready = nwState {
                        continuation.resume()
                    }
                    if case .failed(let error) = nwState {
                        self?.state = .error(error.localizedDescription)
                        continuation.resume()
                    }
                }
            }
        }

        guard case .connected = state else { return }

        state = .handshaking
        await sendHandshake(infoHash: infoHash)
        await receiveHandshake(infoHash: infoHash)

        guard case .connected = state else { return }

        await sendInterested()
        await startReceiving()
    }

    public func disconnect() {
        connection?.cancel()
        state = .disconnected
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

        let length = UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3])

        if length == 0 {
            buffer.removeFirst(4)
            return .keepAlive
        }

        let totalLength = 4 + Int(length)
        guard buffer.count >= totalLength else { return nil }

        let messageData = buffer[..<totalLength]
        buffer.removeFirst(totalLength)

        return WireMessage.decode(messageData)
    }

    private func handleMessage(_ message: WireMessage) async {
        switch message {
        case .choke:
            isChoked = true
            state = .choked
        case .unchoke:
            isChoked = false
            state = .unchoked
            await requestPieces()
        case .interested:
            let message = WireMessage.unchoke.encode()
            connection?.send(content: message, completion: .contentProcessed { _ in })
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
            guard let request = await pieceManager.getNextRequest() else { break }
            if !peerBitfield.isEmpty, !peerHasPiece(request.pieceIndex) { continue }

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

        onPieceReceived?(pieceIndex, offset, block)
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
