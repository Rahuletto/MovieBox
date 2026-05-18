import Foundation

/// BitTorrent handshakes require exactly 20 bytes for the peer id field.
enum BitTorrentPeerID {
    static func make(prefix: String = "-MB0001-") -> String {
        var id = prefix
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while id.utf8.count < 20 {
            id.append(alphabet.randomElement() ?? "a")
        }
        if id.utf8.count > 20 {
            id = String(id.prefix(20))
        }
        return id
    }

    static func data(for peerId: String) -> Data {
        var bytes = Data(peerId.utf8.prefix(20))
        if bytes.count < 20 {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 20 - bytes.count))
        }
        return bytes
    }
}
