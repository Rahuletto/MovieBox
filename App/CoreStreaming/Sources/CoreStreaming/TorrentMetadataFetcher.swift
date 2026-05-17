import Foundation

/// Resolves a real `TorrentMetadata` (piece length, piece hashes, file layout) for a magnet/info-hash.
public enum TorrentMetadataFetcher {
    public enum FetchError: LocalizedError {
        case invalidInfoHash
        case torrentFileUnavailable
        case infoHashMismatch

        public var errorDescription: String? {
            switch self {
            case .invalidInfoHash: "Invalid torrent info hash."
            case .torrentFileUnavailable:
                "Could not download torrent metadata for this release. Try another version from the list."
            case .infoHashMismatch: "Downloaded torrent metadata does not match this magnet link."
            }
        }
    }

    public static func fetch(infoHash: String, magnetTrackers: [String] = []) async throws -> TorrentMetadata {
        let normalized = infoHash.lowercased()
        guard normalized.count == 40,
              normalized.range(of: "^[a-f0-9]+$", options: .regularExpression) != nil else {
            throw FetchError.invalidInfoHash
        }

        let candidateURLs = [
            "https://itorrents.org/torrent/\(normalized.uppercased()).torrent",
            "https://itorrents.org/torrent/\(normalized).torrent"
        ]

        for urlString in candidateURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                request.setValue("MovieBox/1.0", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continue
                }
                guard data.count > 64 else { continue }

                var metadata = try TorrentFileParser.parse(data: data)
                guard metadata.infoHash.lowercased() == normalized else {
                    throw FetchError.infoHashMismatch
                }

                var trackers = metadata.trackers
                for tracker in magnetTrackers where !trackers.contains(tracker) {
                    trackers.append(tracker)
                }
                if trackers.isEmpty {
                    trackers = ["udp://tracker.opentrackr.org:1337/announce"]
                }

                metadata = TorrentMetadata(
                    infoHash: metadata.infoHash,
                    name: metadata.name,
                    totalSize: metadata.totalSize,
                    pieceLength: metadata.pieceLength,
                    pieces: metadata.pieces,
                    files: metadata.files,
                    trackers: trackers
                )
                return metadata
            } catch let error as FetchError {
                throw error
            } catch {
                continue
            }
        }

        throw FetchError.torrentFileUnavailable
    }
}
