import XCTest
@testable import CoreStreaming

final class TrackerEncodingTests: XCTestCase {
    func testInfoHashPercentEncodingUsesRawBytes() {
        let encoded = TrackerEncoding.percentEncodeInfoHash(hex: "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(encoded.count, 60)
        XCTAssertTrue(encoded.hasPrefix("%01%23"))
        XCTAssertFalse(encoded.contains("0123456789"))
    }
}

final class DHTCodecTests: XCTestCase {
    func testCompactNodeRoundTrip() {
        let nodes = [
            DHTNode(nodeId: Data(repeating: 1, count: 20), address: "192.168.1.10", port: 6881),
            DHTNode(nodeId: Data(repeating: 2, count: 20), address: "10.0.0.5", port: 51413),
        ]
        let encoded = DHTCodec.encodeCompactNodes(nodes)
        XCTAssertEqual(encoded.count, 52)
        let decoded = DHTCodec.decodeCompactNodes(encoded)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].address, "192.168.1.10")
        XCTAssertEqual(decoded[0].port, 6881)
        XCTAssertEqual(decoded[1].port, 51413)
    }

    func testCompactPeersDecode() {
        var data = Data()
        data.append(contentsOf: [192, 168, 0, 1, 0x1A, 0xE1])
        let peers = DHTCodec.decodeCompactPeers(data)
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers[0].ip, "192.168.0.1")
        XCTAssertEqual(peers[0].port, 6881)
    }
}
