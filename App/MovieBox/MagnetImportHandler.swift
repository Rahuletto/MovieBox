import CoreStreaming
import Foundation

enum MagnetImportHandler {
    enum ImportError: LocalizedError {
        case unreadableFile
        case invalidTorrentFile
        case unsupportedURL

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                "Could not read the torrent file."
            case .invalidTorrentFile:
                "This file is not a valid .torrent document."
            case .unsupportedURL:
                "MovieBox can open magnet links and .torrent files."
            }
        }
    }

    @MainActor
    static func handle(url: URL, router: AppRouter) throws {
        if url.isFileURL {
            try importTorrentFile(at: url, router: router)
            return
        }

        if url.scheme?.lowercased() == "magnet" {
            router.importMagnet(url.absoluteString)
            return
        }

        if let magnet = extractMagnet(from: url.absoluteString) {
            router.importMagnet(magnet)
            return
        }

        throw ImportError.unsupportedURL
    }

    @MainActor
    static func importTorrentFile(at url: URL, router: AppRouter) throws {
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

        router.importMagnet(metadata.magnetURI)
    }

    static func extractMagnet(from text: String) -> String? {
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

    /// Normalizes a pasted hash or full magnet into something the Downloads UI accepts.
    static func normalizeUserInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let magnet = extractMagnet(from: trimmed) {
            return magnet
        }
        if trimmed.count == 40,
           trimmed.range(of: "^[a-fA-F0-9]+$", options: .regularExpression) != nil {
            return "magnet:?xt=urn:btih:\(trimmed)"
        }
        return trimmed
    }
}
