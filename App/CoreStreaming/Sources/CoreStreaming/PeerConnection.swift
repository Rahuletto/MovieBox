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
    case extended(extendedID: UInt8, payload: Data)
    case ignored(messageId: UInt8)

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
        case .extended(let extID, let payload):
            let length = UInt32(1 + 1 + payload.count)
            data.append(contentsOf: length.bigEndianBytes)
            data.append(20)
            data.append(extID)
            data.append(payload)
        case .ignored:
            break
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
        case 20:
            guard cleanData.count >= 6 else { return nil }
            let extID = cleanData[5]
            return .extended(extendedID: extID, payload: Data(cleanData[6...]))
        default:
            return .ignored(messageId: messageId)
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
    private let parserBuffer = PeerConnectionBuffer()
    private var isChoked = true
    private var peerBitfield: Data = Data()
    private var pieceManager: PieceManager?
    private var onPieceReceived: ((UInt32, UInt32, Data) async -> Void)?
    private var onPeersDiscovered: (@Sendable ([PeerInfo]) async -> Void)?
    public var onOutboundBytes: ((Int) -> Void)?
    private var peerSupportsExtensions = false
    private var peerSupportsPex = false
    private var peerPexID: UInt8?
    private var outstandingRequests: Set<BlockRequest> = []
    private var requestSentAt: [BlockRequest: Date] = [:]
    private var keepaliveTask: Task<Void, Never>?
    private var connectionStarted = Date.now

    private var maxOutstanding = 12
    private let requestTimeout: TimeInterval = 3.5
    private let peerQueue = DispatchQueue(label: "com.moviebox.peer-connection", qos: .userInitiated)

    public init(peerInfo: PeerInfo, connectionPeerId: String) {
        self.peerInfo = peerInfo
        self.peerId = connectionPeerId
    }

    public func connect(
        infoHash: String,
        pieceManager: PieceManager,
        onPieceReceived: @escaping (UInt32, UInt32, Data) async -> Void,
        onPeersDiscovered: (@Sendable ([PeerInfo]) async -> Void)? = nil
    ) async {
        self.pieceManager = pieceManager
        self.onPieceReceived = onPieceReceived
        self.onPeersDiscovered = onPeersDiscovered
        state = .connecting
        connectionStarted = Date.now

        guard peerInfo.port > 0, peerInfo.port < 65536,
              let port = NWEndpoint.Port(rawValue: UInt16(peerInfo.port)) else {
            state = .error("Invalid peer address")
            return
        }

        TorrentLog.debug("[PeerConnection] Connecting to \(peerInfo.ip):\(peerInfo.port)")
        let host = NWEndpoint.Host(peerInfo.ip)

        let parameters = NWParameters.tcp
        parameters.serviceClass = .responsiveData
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

        if peerSupportsExtensions {
            let handshakeDict: BencodeValue = .dictionary([
                "m": .dictionary([
                    "ut_pex": .integer(1)
                ])
            ])
            let handshakePayload = BencodeParser.encode(handshakeDict)
            await sendExtendedMessage(extendedID: 0, payload: handshakePayload)
        }

        let pieceCount = pieceManager.pieceCount
        sendLeecherBitfield(pieceCount: pieceCount)
        await sendInterested()

        do {
            while let message = try parseNextMessageFromBuffer(buffer: parserBuffer, ip: peerInfo.ip, port: peerInfo.port) {
                await handleMessage(message)
                guard isActive else { return }
            }
        } catch {
            TorrentLog.warn("[PeerConnection] Error parsing handshake trailer from \(peerInfo.ip):\(peerInfo.port): \(error.localizedDescription)")
            disconnect()
            return
        }

        if isActive, !isChoked {
            await requestPieces()
        }

        guard isActive else { return }

        await startReceiving()
        startKeepalive()
    }

    public var handshakeAge: TimeInterval {
        Date.now.timeIntervalSince(connectionStarted)
    }

    public func disconnect() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        recycleOutstandingRequests()
        parserBuffer.modify { $0.removeAll(keepingCapacity: false) }
        peerBitfield = Data()
        // Release closure captures (they hold strong refs to TorrentEngine callbacks).
        onPieceReceived = nil
        onPeersDiscovered = nil
        onOutboundBytes = nil
        pieceManager = nil
        connection?.cancel()
        connection = nil
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

            connection.start(queue: peerQueue)

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

        if case .error = state { return false }
        if case .disconnected = state { return false }
        return true
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

    private func sendOutbound(_ data: Data) {
        guard !data.isEmpty else { return }
        onOutboundBytes?(data.count)
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendHandshake(infoHash: String) async {
        var handshake = Data()
        handshake.append(19)
        handshake.append(contentsOf: "BitTorrent protocol".utf8)
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10 // Enable extension protocol support (BEP 10)
        handshake.append(contentsOf: reserved)
        handshake.append(contentsOf: HexEncoding.data(fromHex: infoHash))
        handshake.append(BitTorrentPeerID.data(for: peerId))
        sendOutbound(handshake)
    }

    private static let handshakeLength = 68

    private func receiveHandshake(infoHash: String) async {
        var pending = Data()

        while pending.count < Self.handshakeLength {
            guard let chunk = await receiveSocketChunk(maxLength: 256) else {
                if case .error = state {} else {
                    state = .error("Invalid handshake")
                }
                return
            }
            pending.append(chunk)
        }

        let handshake = pending.prefix(Self.handshakeLength)
        if pending.count > Self.handshakeLength {
            parserBuffer.append(pending.suffix(from: Self.handshakeLength))
        }

        guard handshake.count == Self.handshakeLength else {
            state = .error("Invalid handshake")
            return
        }

        let pstrLength = Int(handshake[handshake.startIndex])
        guard pstrLength == 19 else {
            state = .error("Invalid protocol string")
            return
        }
        let pstr = String(data: handshake[1..<(1 + pstrLength)], encoding: .utf8)
        guard pstr == "BitTorrent protocol" else {
            state = .error("Invalid protocol string")
            return
        }

        let peerInfoHashStart = 1 + pstrLength + 8
        let peerInfoHashEnd = peerInfoHashStart + 20
        let peerHash = handshake[peerInfoHashStart..<peerInfoHashEnd]

        if peerHash.hexString != infoHash.lowercased() {
            state = .error("Info hash mismatch")
            return
        }

        let reservedStart = 1 + pstrLength
        let handshakeData = Data(handshake)
        peerSupportsExtensions = (handshakeData[reservedStart + 5] & 0x10) != 0

        state = .connected
    }

    private func receiveSocketChunk(maxLength: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            connection?.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { [weak self] data, _, isComplete, error in
                Task { @MainActor [weak self] in
                    if let error {
                        self?.state = .error(error.localizedDescription)
                        continuation.resume(returning: nil)
                        return
                    }
                    if isComplete {
                        self?.state = .disconnected
                        continuation.resume(returning: nil)
                        return
                    }
                    guard let data, !data.isEmpty else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private func sendLeecherBitfield(pieceCount: Int) {
        guard pieceCount > 0 else { return }
        let length = (pieceCount + 7) / 8
        let field = Data(repeating: 0, count: length)
        sendOutbound(WireMessage.bitfield(field).encode())
    }

    private func sendInterested() async {
        sendOutbound(WireMessage.interested.encode())
        if !isChoked {
            await requestPieces()
        }
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard let self, isActive else { return }
                self.sendOutbound(WireMessage.keepAlive.encode())
            }
        }
    }

    private func startReceiving() async {
        await receiveMessages()
    }

    private func receiveMessages() async {
        guard isActive, let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            let suffix = data
            let buffer = self.parserBuffer
            let ip = self.peerInfo.ip
            let port = self.peerInfo.port

            var parsedMessages: [WireMessage] = []
            var shouldDisconnect = false
            var disconnectReason = ""

            if let suffix, !suffix.isEmpty {
                buffer.append(suffix)
                let count = buffer.modify { $0.count }
                if count > 512 * 1024 {
                    shouldDisconnect = true
                    disconnectReason = "Wire buffer exceeded 512 KB"
                } else {
                    do {
                        while let message = try self.parseNextMessageFromBuffer(buffer: buffer, ip: ip, port: port) {
                            parsedMessages.append(message)
                        }
                    } catch ParseError.invalidLength(let length) {
                        shouldDisconnect = true
                        disconnectReason = "Invalid wire length \(length) (likely encrypted or misaligned stream)"
                    } catch ParseError.undecodable(let len) {
                        shouldDisconnect = true
                        disconnectReason = "Undecodable \(len)B wire frame (stream desync)"
                    } catch {
                        shouldDisconnect = true
                        disconnectReason = "Parse error: \(error.localizedDescription)"
                    }
                }
            }

            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }

                if let error {
                    self.state = .error(error.localizedDescription)
                    self.recycleOutstandingRequests()
                    return
                }

                if shouldDisconnect {
                    TorrentLog.warn("[PeerConnection] \(disconnectReason) from \(self.peerInfo.ip):\(self.peerInfo.port) — disconnecting")
                    self.disconnect()
                    return
                }

                for message in parsedMessages {
                    guard self.isActive else { break }
                    await self.handleMessage(message)
                }

                if isComplete {
                    self.state = .disconnected
                    self.recycleOutstandingRequests()
                    return
                }

                guard self.isActive else { return }
                await self.receiveMessages()
            }
        }
    }

    nonisolated private func parseNextMessageFromBuffer(buffer: PeerConnectionBuffer, ip: String, port: Int) throws -> WireMessage? {
        try buffer.modify { data in
            guard data.count >= 4 else { return nil }

            let start = data.startIndex
            let b0 = UInt32(data[start])
            let b1 = UInt32(data[start + 1])
            let b2 = UInt32(data[start + 2])
            let b3 = UInt32(data[start + 3])
            let length = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

            if length == 0 {
                data.removeSubrange(start..<(start + 4))
                return .keepAlive
            }

            guard length <= 262_144 else {
                throw ParseError.invalidLength(length)
            }

            let totalLength = 4 + Int(length)
            guard totalLength > 4, data.count >= totalLength else { return nil }

            let messageData = Data(data[start..<(start + totalLength)])
            guard let message = WireMessage.decode(messageData) else {
                throw ParseError.undecodable(totalLength)
            }

            data.removeSubrange(start..<(start + totalLength))
            return message
        }
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
        case .extended(let extID, let payload):
            await handleExtendedMessage(extID: extID, payload: payload)
        case .request, .cancel, .port, .keepAlive, .ignored:
            break
        }
    }

    private func sendExtendedMessage(extendedID: UInt8, payload: Data) async {
        let msg = WireMessage.extended(extendedID: extendedID, payload: payload)
        sendOutbound(msg.encode())
    }

    private func handleExtendedMessage(extID: UInt8, payload: Data) async {
        if extID == 0 { // Extension handshake
            guard let dict = try? BencodeParser.parse(payload).dictionary else { return }
            if let extensions = dict["m"]?.dictionary,
               let pexID = extensions["ut_pex"]?.integer {
                peerSupportsPex = true
                peerPexID = UInt8(clamping: pexID)
                TorrentLog.info("[PeerConnection] Peer \(peerInfo.ip):\(peerInfo.port) supports PEX (remote message ID = \(peerPexID!))")
            }
        } else if peerSupportsPex, extID == 1 { // Incoming PEX message
            guard let dict = try? BencodeParser.parse(payload).dictionary else { return }
            if case .string(let addedData) = dict["added"] {
                let discovered = DHTCodec.decodeCompactPeers(addedData)
                if !discovered.isEmpty {
                    TorrentLog.info("[PeerConnection] Received PEX update from \(peerInfo.ip):\(peerInfo.port) containing \(discovered.count) peers")
                    if let callback = onPeersDiscovered {
                        await callback(discovered)
                    }
                }
            }
        }
    }

    private func setPeerHasPiece(_ pieceIndex: UInt32) {
        let byteIndex = Int(pieceIndex / 8)
        let bitIndex = Int(pieceIndex % 8)
        // Cap growth: a bitfield for 1M pieces is 125 KB. Reject absurd indices from
        // buggy/malicious peers that would balloon this Data per connection.
        guard byteIndex < 131_072 else { return } // 1M piece cap
        if peerBitfield.count <= byteIndex {
            peerBitfield.append(contentsOf: [UInt8](repeating: 0, count: byteIndex - peerBitfield.count + 1))
        }
        peerBitfield[byteIndex] |= (1 << (7 - bitIndex))
    }

    /// Request more blocks using current `PieceManager` priority (e.g. after AVPlayer seek).
    public func scheduleAdditionalRequests() {
        guard isActive else { return }
        Task { await reprioritizeAndRequestPieces() }
    }

    private func reprioritizeAndRequestPieces() async {
        guard let pieceManager else { return }
        var cancelled: [BlockRequest] = []
        for request in outstandingRequests {
            if await !pieceManager.isRequestStillInPlaybackWindow(request) {
                cancelled.append(request)
                outstandingRequests.remove(request)
                requestSentAt.removeValue(forKey: request)
                let cancel = WireMessage.cancel(
                    pieceIndex: request.pieceIndex,
                    offset: request.offset,
                    length: request.length
                )
                sendOutbound(cancel.encode())
            }
        }
        if !cancelled.isEmpty {
            await pieceManager.recycleRequests(cancelled)
        }
        await requestPieces()
    }

    private func requestPieces() async {
        guard let pieceManager, !isChoked, !peerBitfield.isEmpty else { return }

        let availableSlots = maxOutstanding - outstandingRequests.count
        guard availableSlots > 0 else { return }

        state = .downloading

        for _ in 0..<availableSlots {
            guard let request = await pieceManager.getNextRequest(peerBitfield: peerBitfield) else { break }

            outstandingRequests.insert(request)
            requestSentAt[request] = Date.now

            // Cap the request-time dictionary; stale entries from out-of-order delivery
            // would otherwise accumulate to the lifetime of the connection.
            if requestSentAt.count > 256 {
                let cutoff = Date.now.addingTimeInterval(-requestTimeout * 2)
                requestSentAt = requestSentAt.filter { $0.value > cutoff }
            }

            let message = WireMessage.request(
                pieceIndex: request.pieceIndex,
                offset: request.offset,
                length: request.length
            )
            sendOutbound(message.encode())
        }
    }

    private func handlePiece(pieceIndex: UInt32, offset: UInt32, block: Data) async {
        let completed = BlockRequest(pieceIndex: pieceIndex, offset: offset, length: 0)
        let sentAt = requestSentAt[completed]
        outstandingRequests.remove(completed)
        requestSentAt.removeValue(forKey: completed)
        piecesReceived += 1

        if let sentAt {
            let rtt = Date.now.timeIntervalSince(sentAt)
            if rtt < 0.35 {
                maxOutstanding = min(28, maxOutstanding + 1)
            } else if rtt > 1.2 {
                maxOutstanding = max(4, maxOutstanding - 1)
            }
        }

        if let callback = onPieceReceived {
            await callback(pieceIndex, offset, block)
        }
        await requestPieces()
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

private final class PeerConnectionBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    func append(_ other: Data) {
        lock.lock()
        defer { lock.unlock() }
        _data.append(other)
    }

    func modify<T>(_ body: (inout Data) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&_data)
    }
}

private enum ParseError: Error {
    case invalidLength(UInt32)
    case undecodable(Int)
}
