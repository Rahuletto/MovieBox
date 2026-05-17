import Foundation
import CryptoKit

// MARK: - Magnet URI Parser

public struct MagnetURI: Sendable, Hashable {
    public let infoHash: String
    public let displayName: String?
    public let trackers: [String]

    public init(infoHash: String, displayName: String? = nil, trackers: [String] = []) {
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
    }

    public init?(from magnetURI: String) {
        guard magnetURI.hasPrefix("magnet:?") else { return nil }

        let query = String(magnetURI.dropFirst(8))
        var rawInfoHash: String?
        var displayName: String?
        var trackers: [String] = []

        let pairs = query.components(separatedBy: "&")
        for pair in pairs {
            let parts = pair.components(separatedBy: "=")
            guard parts.count == 2 else { continue }

            let key = parts[0]
            let value = parts[1].removingPercentEncoding ?? parts[1]

            switch key {
            case "xt":
                if value.hasPrefix("urn:btih:") {
                    rawInfoHash = String(value.dropFirst(9)).lowercased()
                }
            case "dn":
                displayName = value
            case "tr":
                trackers.append(value)
            default:
                break
            }
        }

        guard let rawHash = rawInfoHash else { return nil }

        let finalHash: String
        if rawHash.count == 40 {
            finalHash = rawHash
        } else if rawHash.count == 32, let decoded = Self.decodeBase32(rawHash) {
            finalHash = decoded
        } else {
            return nil
        }

        self.infoHash = finalHash
        self.displayName = displayName
        self.trackers = trackers
    }

    private static func decodeBase32(_ input: String) -> String? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = ""

        for char in input.uppercased() {
            guard let index = alphabet.firstIndex(of: char) else { continue }
            let value = alphabet.distance(from: alphabet.startIndex, to: index)
            bits += String(value, radix: 2).paddingToLeft(5)
        }

        var hexBytes = ""
        while bits.count >= 8 {
            let byte = String(bits.prefix(8))
            bits = String(bits.dropFirst(8))
            if let value = UInt8(byte, radix: 2) {
                hexBytes += String(format: "%02x", value)
            }
        }

        return hexBytes.isEmpty ? nil : hexBytes
    }
}

private extension String {
    func paddingToLeft(_ length: Int) -> String {
        if count >= length { return self }
        return String(repeating: "0", count: length - count) + self
    }
}

// MARK: - Torrent Metadata

public struct TorrentMetadata: Sendable {
    public let infoHash: String
    public let name: String
    public let totalSize: Int64
    public let pieceLength: Int64
    public let pieceCount: Int
    public let pieces: Data
    public let files: [TorrentFile]
    public let trackers: [String]

    public init(
        infoHash: String,
        name: String,
        totalSize: Int64,
        pieceLength: Int64,
        pieces: Data,
        files: [TorrentFile],
        trackers: [String] = []
    ) {
        self.infoHash = infoHash
        self.name = name
        self.totalSize = totalSize
        self.pieceLength = pieceLength
        self.pieceCount = Int((totalSize + pieceLength - 1) / pieceLength)
        self.pieces = pieces
        self.files = files
        self.trackers = trackers
    }
}

public struct TorrentFile: Sendable {
    public let path: [String]
    public let length: Int64

    public var relativePath: String {
        path.joined(separator: "/")
    }
}

// MARK: - Torrent File Parser

public enum TorrentFileParser {
    /// Parses a bencoded `info` dictionary (from `ut_metadata` or similar).
    public static func parse(
        infoBencoded: Data,
        expectedInfoHash: String,
        trackers: [String]
    ) throws -> TorrentMetadata {
        guard infoBencoded.sha1Hex == expectedInfoHash.lowercased() else {
            throw TorrentMetadataFetcher.FetchError.infoHashMismatch
        }
        guard let infoDict = try BencodeParser.parse(infoBencoded).dictionary else {
            throw TorrentParserError.invalidFormat
        }
        return try metadata(from: infoDict, infoHash: expectedInfoHash.lowercased(), trackers: trackers)
    }

    public static func parse(data: Data) throws -> TorrentMetadata {
        let bencode = try BencodeParser.parse(data)
        guard let dict = bencode.dictionary else {
            throw TorrentParserError.invalidFormat
        }

        guard let infoDict = dict["info"]?.dictionary else {
            throw TorrentParserError.missingInfo
        }

        let infoData = try extractInfoData(from: data)
        let infoHash = infoData.sha1Hex

        var mergedTrackers: [String] = []
        if case .string(let trackerData) = dict["announce"] {
            if let tracker = String(data: trackerData, encoding: .utf8) {
                mergedTrackers.append(tracker)
            }
        }
        if let announceList = dict["announce-list"]?.list {
            for tier in announceList {
                if let tierList = tier.list {
                    for tracker in tierList {
                        if case .string(let trackerData) = tracker,
                           let trackerString = String(data: trackerData, encoding: .utf8) {
                            mergedTrackers.append(trackerString)
                        }
                    }
                }
            }
        }

        return try metadata(from: infoDict, infoHash: infoHash, trackers: mergedTrackers)
    }

    private static func metadata(
        from infoDict: [String: BencodeValue],
        infoHash: String,
        trackers: [String]
    ) throws -> TorrentMetadata {
        let name: String
        if let nameValue = infoDict["name"]?.string {
            name = nameValue
        } else {
            name = "Unknown"
        }

        let pieceLength = infoDict["piece length"]?.integer ?? 0
        let pieces = infoDict["pieces"]
        let piecesData: Data
        if case .string(let data) = pieces {
            piecesData = data
        } else {
            throw TorrentParserError.missingPieces
        }

        var files: [TorrentFile] = []
        if let length = infoDict["length"]?.integer {
            files.append(TorrentFile(path: [name], length: length))
        } else if let fileArray = infoDict["files"]?.list {
            for fileValue in fileArray {
                guard let fileDict = fileValue.dictionary,
                      let length = fileDict["length"]?.integer,
                      let pathList = fileDict["path"]?.list else { continue }
                let pathComponents = pathList.compactMap { $0.string }
                files.append(TorrentFile(path: [name] + pathComponents, length: length))
            }
        }

        let totalSize = files.reduce(0) { $0 + $1.length }

        return TorrentMetadata(
            infoHash: infoHash,
            name: name,
            totalSize: totalSize,
            pieceLength: pieceLength,
            pieces: piecesData,
            files: files,
            trackers: trackers
        )
    }

    private static func extractInfoData(from data: Data) throws -> Data {
        var index = data.startIndex
        guard data[index] == UInt8(ascii: "d") else {
            throw TorrentParserError.invalidFormat
        }
        index += 1

        while index < data.endIndex {
            if data[index] == UInt8(ascii: "e") {
                break
            }

            var lengthEnd = index
            while lengthEnd < data.endIndex, data[lengthEnd] != UInt8(ascii: ":") {
                lengthEnd += 1
            }
            guard lengthEnd < data.endIndex else {
                throw TorrentParserError.invalidFormat
            }

            let lengthData = data[index..<lengthEnd]
            guard let lengthString = String(data: lengthData, encoding: .ascii),
                  let length = Int(lengthString) else {
                throw TorrentParserError.invalidFormat
            }

            let keyStart = lengthEnd + 1
            let keyEnd = keyStart + length
            guard keyEnd <= data.endIndex else {
                throw TorrentParserError.invalidFormat
            }

            let keyData = data[keyStart..<keyEnd]
            if let key = String(data: keyData, encoding: .utf8), key == "info" {
                let valueStart = keyEnd
                var valueIndex = valueStart
                _ = try skipBencodeValue(data, at: &valueIndex)
                return data[valueStart..<valueIndex]
            }

            index = keyEnd
            _ = try skipBencodeValue(data, at: &index)
        }

        throw TorrentParserError.missingInfo
    }

    private static func skipBencodeValue(_ data: Data, at index: inout Data.Index) throws -> Data.Index {
        guard index < data.endIndex else {
            throw TorrentParserError.invalidFormat
        }

        switch data[index] {
        case UInt8(ascii: "i"):
            index += 1
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                index += 1
            }
            index += 1
        case UInt8(ascii: "l"), UInt8(ascii: "d"):
            let marker = data[index]
            index += 1
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                _ = try skipBencodeValue(data, at: &index)
            }
            index += 1
        case let b where b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"):
            var lengthEnd = index
            while lengthEnd < data.endIndex, data[lengthEnd] != UInt8(ascii: ":") {
                lengthEnd += 1
            }
            guard lengthEnd < data.endIndex else {
                throw TorrentParserError.invalidFormat
            }
            let lengthData = data[index..<lengthEnd]
            guard let lengthString = String(data: lengthData, encoding: .ascii),
                  let length = Int(lengthString) else {
                throw TorrentParserError.invalidFormat
            }
            index = lengthEnd + 1 + length
        default:
            throw TorrentParserError.invalidFormat
        }

        return index
    }
}

extension TorrentMetadata {
    /// Builds a magnet URI suitable for `MagnetURI` and the Downloads import UI.
    public var magnetURI: String {
        var components = ["magnet:?xt=urn:btih:\(infoHash)"]
        if let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            components.append("dn=\(encodedName)")
        }
        for tracker in trackers.prefix(8) {
            if let encoded = tracker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                components.append("tr=\(encoded)")
            }
        }
        return components.joined(separator: "&")
    }
}

public enum TorrentParserError: Error, LocalizedError {
    case invalidFormat
    case missingInfo
    case missingPieces

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "Invalid torrent file format"
        case .missingInfo: "Missing 'info' dictionary in torrent file"
        case .missingPieces: "Missing 'pieces' data in torrent info"
        }
    }
}

// MARK: - SHA1 Helper

private extension Data {
    var sha1Hex: String {
        let hash = Insecure.SHA1.hash(data: self)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
