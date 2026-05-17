import Foundation

public enum MovieBoxError: Error, LocalizedError, Sendable {
    case network(Error)
    case parsing(String)
    case notFound(String)
    case unauthorized(String)
    case timeout
    case unavailable(String)
    case invalidState(String)
    case storage(Error)
    case streaming(String)
    case subtitle(String)

    public var errorDescription: String? {
        switch self {
        case .network(let error):
            "Network error: \(error.localizedDescription)"
        case .parsing(let message):
            "Failed to parse data: \(message)"
        case .notFound(let resource):
            "\(resource) not found"
        case .unauthorized(let message):
            "Unauthorized: \(message)"
        case .timeout:
            "Request timed out. Please try again."
        case .unavailable(let message):
            "Service unavailable: \(message)"
        case .invalidState(let message):
            "Invalid state: \(message)"
        case .storage(let error):
            "Storage error: \(error.localizedDescription)"
        case .streaming(let message):
            "Streaming error: \(message)"
        case .subtitle(let message):
            "Subtitle error: \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .network:
            "Check your internet connection and try again."
        case .parsing:
            "The data format may have changed. Please report this issue."
        case .notFound:
            "The requested resource may have been removed."
        case .unauthorized:
            "Please check your API keys or authentication token in Settings."
        case .timeout:
            "The server took too long to respond. Try again later."
        case .unavailable:
            "The service is temporarily unavailable. Try again later."
        case .invalidState:
            "An unexpected state occurred. Please restart the app."
        case .storage:
            "There may be an issue with local storage. Try clearing cache."
        case .streaming:
            "Streaming failed. Try a different torrent or check your connection."
        case .subtitle:
            "Subtitle could not be loaded. Try a different subtitle file."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .network, .timeout, .unavailable, .streaming:
            true
        case .parsing, .notFound, .unauthorized, .invalidState, .storage, .subtitle:
            false
        }
    }
}

public extension Error {
    var asMovieBoxError: MovieBoxError {
        if let mbError = self as? MovieBoxError {
            return mbError
        }
        if let urlError = self as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return .network(self)
            case .timedOut:
                return .timeout
            case .cannotFindHost, .cannotConnectToHost:
                return .unavailable("Host unreachable")
            case .secureConnectionFailed:
                return .unavailable("Secure connection failed")
            default:
                return .network(self)
            }
        }
        return .network(self)
    }
}

public actor ErrorTracker {
    private var errorCounts: [String: Int] = [:]
    private var lastErrorTime: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 60

    public init() {}

    public func track(_ error: MovieBoxError, context: String) -> Bool {
        let key = "\(context):\(error.errorDescription ?? "")"
        let now = Date()

        if let lastTime = lastErrorTime[key], now.timeIntervalSince(lastTime) < cooldownInterval {
            errorCounts[key, default: 0] += 1
            if errorCounts[key]! > 3 {
                return false
            }
        } else {
            errorCounts[key] = 1
        }

        lastErrorTime[key] = now
        return true
    }

    public func reset(context: String) {
        errorCounts.filter { $0.key.hasPrefix("\(context):") }.forEach { errorCounts[$0.key] = nil }
        lastErrorTime.filter { $0.key.hasPrefix("\(context):") }.forEach { lastErrorTime[$0.key] = nil }
    }
}
