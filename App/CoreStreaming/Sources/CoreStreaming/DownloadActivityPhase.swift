import Foundation

/// Finer-grained download UI state while `DownloadState` remains `.downloading`.
public enum DownloadActivityPhase: String, Sendable, Equatable {
    case downloading
    case waitingForFinalPieces
    case assembling

    /// Short label for pills and badges (not the full `statusDetail` line).
    public var shortLabel: String {
        switch self {
        case .downloading:
            "Downloading"
        case .waitingForFinalPieces:
            "Finishing download"
        case .assembling:
            "Finishing"
        }
    }
}
