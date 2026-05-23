import CoreStorage
import Foundation

/// Appends NDJSON debug lines to `~/Library/Logs/MovieBox/moviebox.log` (live, same file as TorrentLog).
enum DebugSessionLog {
    /// Bump when logging format or streaming debug paths change.
    static let logVersion = "20260522-moov-tail-order-v4"

    private static let sessionId = "828a86"

    static var filePath: String {
        MovieBoxFileLogger.logFileURL.path
    }

    /// Appends a versioned session banner (does not truncate `moviebox.log`).
    static func purge(infoHash: String) {
        // #region agent log
        let header: [String: Any] = [
            "type": "session_start",
            "logVersion": logVersion,
            "sessionId": sessionId,
            "infoHash": infoHash,
            "logFile": filePath,
            "timestamp": timestampMs(),
        ]
        if let json = encodeLine(header) {
            MovieBoxFileLogger.appendRaw(
                "\n--- [debug-828a86/\(logVersion)] SESSION_START ---\n\(json)\n"
            )
        }
        TorrentLog.info(
            "[debug-828a86] session \(logVersion) → appending to \(filePath)"
        )
        // #endregion
    }

    /// Live-append one NDJSON event to `moviebox.log`.
    static func event(
        _ message: String,
        location: String,
        data: [String: Any] = [:]
    ) {
        // #region agent log
        var payload: [String: Any] = [
            "type": "event",
            "logVersion": logVersion,
            "sessionId": sessionId,
            "location": location,
            "message": message,
            "timestamp": timestampMs(),
        ]
        if !data.isEmpty { payload["data"] = data }
        guard let json = encodeLine(payload) else { return }
        MovieBoxFileLogger.appendRaw("[debug-828a86/\(logVersion)] \(json)\n")
        // #endregion
    }

    private static func timestampMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private static func encodeLine(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8)
        else { return nil }
        return line
    }
}
