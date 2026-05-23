import CoreStorage
import Foundation

/// Agent debug lines → `moviebox.log` (same file as TorrentLog).
public enum AgentDebugLog {
    public static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:],
        runId: String = "pre-fix"
    ) {
        // #region agent log
        var payload: [String: Any] = [
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "runId": runId,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if !data.isEmpty { payload["data"] = data }
        if let json = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: json, encoding: .utf8) {
            TorrentLog.info("[agent-debug] \(line)")
        } else {
            TorrentLog.info("[agent-debug] \(hypothesisId) \(location) — \(message)")
        }
        // #endregion
    }
}
