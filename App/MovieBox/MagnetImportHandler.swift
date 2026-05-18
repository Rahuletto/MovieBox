import CoreStreaming
import Foundation
import MovieBoxCore

enum MagnetImportHandler {
    enum ImportError: LocalizedError {
        case unsupportedURL

        var errorDescription: String? {
            switch self {
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

        if let magnet = MagnetLinkParser.extractMagnet(from: url.absoluteString) {
            router.importMagnet(magnet)
            return
        }

        throw ImportError.unsupportedURL
    }

    static func magnetURI(fromTorrentFileAt url: URL) throws -> String {
        try TorrentFileImport.magnetURI(fromTorrentFileAt: url)
    }

    @MainActor
    static func importTorrentFile(at url: URL, router: AppRouter) throws {
        router.importMagnet(try magnetURI(fromTorrentFileAt: url))
    }

    static func normalizeUserInput(_ raw: String) -> String {
        MagnetLinkParser.normalize(raw)
    }
}
