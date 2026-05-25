import Foundation

/// Session debug logging (NDJSON append). Fold regions in CorePlayer call sites.
enum DebugAgentLog {
    private static let logPath = "/Users/marban/Documents/Coding/moviebox/.cursor/debug-d0d1c3.log"

    static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: String] = [:],
        runId: String = "pre-fix"
    ) {
        var payload: [String: Any] = [
            "sessionId": "d0d1c3",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "runId": runId,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8)
        else { return }

        let url = URL(fileURLWithPath: logPath)
        let bytes = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: logPath),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(bytes)
            try? handle.close()
        } else {
            try? bytes.write(to: url, options: .atomic)
        }
    }
}
