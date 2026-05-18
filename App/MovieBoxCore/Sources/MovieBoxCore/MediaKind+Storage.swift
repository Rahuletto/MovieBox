import CoreMetadata
import CoreStorage
import Foundation

public extension MediaKind {
    /// Persisted `MovieRecord` / `DownloadRecord` value.
    var storageValue: String {
        switch self {
        case .movie: "movie"
        case .tv: "tv"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "movie": self = .movie
        case "tv": self = .tv
        default: return nil
        }
    }
}

public extension MovieRecord {
    var mediaKindEnum: MediaKind {
        MediaKind(storageValue: mediaKind) ?? .movie
    }
}

public extension DownloadRecord {
    var mediaKindEnum: MediaKind {
        MediaKind(storageValue: mediaKind) ?? .movie
    }
}
