import CoreStreaming
import CoreTorrent
import Foundation

public enum MagnetLinkParser {
    public static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let magnet = extractMagnet(from: trimmed) {
            return magnet
        }
        if trimmed.count == 40,
           trimmed.range(of: "^[a-fA-F0-9]+$", options: .regularExpression) != nil {
            return "magnet:?xt=urn:btih:\(trimmed)"
        }
        return trimmed
    }

    public static func extractMagnet(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("magnet:?") {
            return trimmed
        }
        if let range = trimmed.range(of: "magnet:?", options: .caseInsensitive) {
            let tail = trimmed[range.lowerBound...]
            let end = tail.firstIndex(where: { $0.isWhitespace }) ?? tail.endIndex
            return String(tail[..<end])
        }
        return nil
    }

    public static func normalizedMagnetOrHTTP(_ input: String) -> Result<String, MagnetParseError> {
        let clean = normalize(input)
        if clean.hasPrefix("http://") || clean.hasPrefix("https://") {
            return .success(clean)
        }
        var parsed = clean
        if clean.count == 40,
           clean.range(of: "^[a-fA-F0-9]+$", options: .regularExpression) != nil {
            parsed = "magnet:?xt=urn:btih:\(clean)"
        }
        guard MagnetURI(from: parsed) != nil else {
            return .failure(.invalidMagnet)
        }
        return .success(parsed)
    }

    public enum MagnetParseError: Error {
        case invalidMagnet
    }
}

public enum TorrentFileImport {
    public enum ImportError: LocalizedError {
        case unreadableFile
        case invalidTorrentFile

        public var errorDescription: String? {
            switch self {
            case .unreadableFile: "Could not read the torrent file."
            case .invalidTorrentFile: "This file is not a valid .torrent document."
            }
        }
    }

    public static func magnetURI(fromTorrentFileAt url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadableFile
        }
        let metadata: TorrentMetadata
        do {
            metadata = try TorrentFileParser.parse(data: data)
        } catch {
            throw ImportError.invalidTorrentFile
        }
        return metadata.magnetURI
    }
}
