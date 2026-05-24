import Foundation

/// Thread-safe append-only logger to `~/Library/Logs/MovieBox/moviebox.log`.
/// Used by `LogStore`, torrent engine, and AVPlayer so agents can read one file.
public enum MovieBoxFileLogger {
    nonisolated(unsafe) public static var isDebugLoggingEnabled: Bool = false

    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    public nonisolated static var logFileURL: URL {
        logsDirectory.appendingPathComponent("moviebox.log", isDirectory: false)
    }

    public nonisolated static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/MovieBox", isDirectory: true)
        return base ?? FileManager.default.temporaryDirectory.appendingPathComponent("MovieBox", isDirectory: true)
    }

    private nonisolated static let maxFileBytes: UInt64 = 5 * 1024 * 1024
    private nonisolated static let fileQueue = DispatchQueue(label: "moviebox.filelogger", qos: .utility)

    public static func log(_ level: Level, category: String, _ message: String) {
        guard isDebugLoggingEnabled || level == .error || level == .warn else { return }
        let line = formatLine(level: level, category: category, message: sanitize(message))
        fileQueue.async {
            ensureLogDirectory()
            rotateIfNeeded()
            appendLine(line + "\n", to: logFileURL)
        }
        NSLog("MovieBox: %@", line)
    }

    /// Session banners / multi-line blocks (no level prefix).
    public static func appendRaw(_ text: String) {
        guard isDebugLoggingEnabled else { return }
        fileQueue.async {
            ensureLogDirectory()
            rotateIfNeeded()
            appendLine(text, to: logFileURL)
        }
    }

    /// Local HTTP stream URLs and magnet links — strip tokens and long query strings.
    public static func redactURL(_ url: URL) -> String {
        redactURLString(url.absoluteString)
    }

    public static func redactURLString(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        if let host = components.host, host == "127.0.0.1" || host == "localhost" {
            return components.scheme.map { "\($0)://\(host):\(components.port ?? 0)/…" } ?? raw
        }
        if var items = components.queryItems, !items.isEmpty {
            for index in items.indices {
                let name = items[index].name.lowercased()
                if name.contains("token") || name.contains("key") || name == "tr" {
                    items[index].value = "<redacted>"
                }
            }
            components.queryItems = items
        }
        let s = components.string ?? raw
        return s.count > 240 ? String(s.prefix(240)) + "…" : s
    }

    public static func redactMagnet(_ magnet: String) -> String {
        guard let hashRange = magnet.range(of: "btih:", options: .caseInsensitive) else {
            return magnet.count > 80 ? String(magnet.prefix(80)) + "…" : magnet
        }
        let after = magnet[hashRange.upperBound...]
        let hash = after.prefix(while: { $0.isHexDigit || $0 == "%" }).prefix(16)
        return "magnet:?xt=urn:btih:\(hash)…"
    }

    // MARK: - Private

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func formatLine(level: Level, category: String, message: String) -> String {
        let ts = isoFormatter.string(from: Date())
        return "[\(ts)] [\(level.rawValue)] [\(category)] \(message)"
    }

    private static func sanitize(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func ensureLogDirectory() {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    private static func appendLine(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return
            }
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func rotateIfNeeded() {
        let url = logFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxFileBytes else { return }
        let backup = logsDirectory.appendingPathComponent("moviebox.log.1", isDirectory: false)
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
