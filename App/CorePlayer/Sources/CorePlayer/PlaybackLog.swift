import Foundation

/// AVPlayer / stream URL diagnostics — always written to `~/Library/Logs/MovieBox/moviebox.log`.
public enum PlaybackLog {
    nonisolated(unsafe) public static var isEnabled = false

    public static func log(_ message: String) {
        guard isEnabled else { return }
        PlaybackFileLog.write(level: "INFO", message: message)
    }

    public static func debug(_ message: String) {
        guard isEnabled else { return }
        PlaybackFileLog.write(level: "DEBUG", message: message)
    }

    public static func warn(_ message: String) {
        PlaybackFileLog.write(level: "WARN", message: message)
    }

    public static func error(_ message: String) {
        PlaybackFileLog.write(level: "ERROR", message: message)
    }

    public static func redactURL(_ url: URL) -> String {
        PlaybackFileLog.redactURLString(url.absoluteString)
    }
}

// MARK: - File log (mirrors CoreStorage.MovieBoxFileLogger format for agent inspection)

private enum PlaybackFileLog {
    private static let fileQueue = DispatchQueue(label: "moviebox.playback.filelog", qos: .utility)

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var logFileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/MovieBox", isDirectory: true)
        return base?.appendingPathComponent("moviebox.log")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MovieBox/moviebox.log")
    }

    static func write(level: String, message: String) {
        let sanitized = message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let ts = isoFormatter.string(from: Date())
        let line = "[\(ts)] [\(level)] [playback] \(sanitized)\n"
        fileQueue.async {
            try? FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            append(line, to: logFileURL)
        }
        NSLog("MovieBox: %@", line.trimmingCharacters(in: .newlines))
    }

    static func redactURLString(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        if let host = components.host, host == "127.0.0.1" || host == "localhost" {
            return "http://\(host):\(components.port ?? 0)/…"
        }
        let s = components.string ?? raw
        return s.count > 240 ? String(s.prefix(240)) + "…" : s
    }

    private static func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
