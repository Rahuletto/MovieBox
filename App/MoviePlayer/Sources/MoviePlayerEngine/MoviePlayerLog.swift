import Foundation
import OSLog

public enum MoviePlayerLog {
    private static let logger = Logger(subsystem: "com.movieplayer", category: "engine")

    public nonisolated(unsafe) static var onLog: (@Sendable (String, String) -> Void)?

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        onLog?("INFO", message)
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        onLog?("WARN", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        onLog?("ERROR", message)
    }
}
