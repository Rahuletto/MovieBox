import Foundation

public enum TorrentLimits {
    /// Reject torrents larger than this to avoid huge sparse files and memory pressure.
    public static let maxTotalSizeBytes: Int64 = 64 * 1024 * 1024 * 1024

    public static func validateTotalSize(_ totalSize: Int64) throws {
        guard totalSize > 0 else {
            throw TorrentLimitsError.invalidSize
        }
        guard totalSize <= maxTotalSizeBytes else {
            throw TorrentLimitsError.tooLarge(totalSize)
        }
    }
}

public enum TorrentLimitsError: Error, LocalizedError {
    case invalidSize
    case tooLarge(Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidSize:
            return "Torrent has invalid size."
        case .tooLarge(let bytes):
            let gb = Double(bytes) / 1_073_741_824
            return String(format: "Torrent is too large (%.1f GB). Maximum is 64 GB.", gb)
        }
    }
}
