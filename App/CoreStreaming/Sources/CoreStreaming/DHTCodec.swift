import Foundation

enum DHTCodec {
    static let compactNodeSize = 26
    static let compactPeerSize = 6

    static func encodeCompactNodes(_ nodes: [DHTNode]) -> Data {
        var data = Data()
        for node in nodes {
            guard node.nodeId.count == 20,
                  let ipv4 = ipv4Bytes(from: node.address) else { continue }
            data.append(node.nodeId)
            data.append(contentsOf: ipv4)
            data.append(UInt8((node.port >> 8) & 0xFF))
            data.append(UInt8(node.port & 0xFF))
        }
        return data
    }

    static func decodeCompactNodes(_ data: Data) -> [DHTNode] {
        var nodes: [DHTNode] = []
        var index = data.startIndex
        while index + compactNodeSize <= data.endIndex {
            let nodeId = Data(data[index..<index + 20])
            let ip = "\(data[index + 20]).\(data[index + 21]).\(data[index + 22]).\(data[index + 23])"
            let port = (Int(data[index + 24]) << 8) | Int(data[index + 25])
            nodes.append(DHTNode(nodeId: nodeId, address: ip, port: port))
            index += compactNodeSize
        }
        return nodes
    }

    static func decodeCompactPeers(_ data: Data) -> [PeerInfo] {
        var peers: [PeerInfo] = []
        var index = data.startIndex
        while index + compactPeerSize <= data.endIndex {
            let ip = "\(data[index]).\(data[index + 1]).\(data[index + 2]).\(data[index + 3])"
            let port = (Int(data[index + 4]) << 8) | Int(data[index + 5])
            peers.append(PeerInfo(ip: ip, port: port, peerId: nil))
            index += compactPeerSize
        }
        return peers
    }

    static func xorDistance(_ a: Data, _ b: Data) -> Data {
        let count = min(a.count, b.count, 20)
        var out = Data(count: 20)
        for i in 0..<count {
            let av = i < a.count ? a[a.startIndex + i] : 0
            let bv = i < b.count ? b[b.startIndex + i] : 0
            out[i] = av ^ bv
        }
        return out
    }

    static func compareDistance(_ a: Data, _ b: Data, to target: Data) -> Bool {
        let da = xorDistance(a, target)
        let db = xorDistance(b, target)
        return da.lexicographicallyPrecedes(db)
    }

    private static func ipv4Bytes(from address: String) -> [UInt8]? {
        let parts = address.split(separator: ".")
        guard parts.count == 4,
              let b0 = UInt8(parts[0]), let b1 = UInt8(parts[1]),
              let b2 = UInt8(parts[2]), let b3 = UInt8(parts[3]) else { return nil }
        return [b0, b1, b2, b3]
    }
}
