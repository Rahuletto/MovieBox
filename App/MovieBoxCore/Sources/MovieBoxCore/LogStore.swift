import Foundation
import os

/// Application logging: bounded in-memory buffer + rotating file on disk.
/// AI agents: see `.agents/LOGGING.md` for log path and usage.
@MainActor
public final class LogStore {
    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    public static let shared = LogStore()

    /// Primary log file for diagnostics and agent inspection.
    public nonisolated static var logFileURL: URL {
        logsDirectory.appendingPathComponent("moviebox.log", isDirectory: false)
    }

    /// macOS standard log directory: `~/Library/Logs/MovieBox/`
    public nonisolated static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/MovieBox", isDirectory: true)
        return base ?? FileManager.default.temporaryDirectory.appendingPathComponent("MovieBox", isDirectory: true)
    }

    private static let maxMemoryLines = 2_000
    private nonisolated static let maxFileBytes: UInt64 = 5 * 1024 * 1024

    private let fileQueue = DispatchQueue(label: "moviebox.logger.file", qos: .utility)
    private let osLog = Logger(subsystem: "com.moviebox.app", category: "general")
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public private(set) var logs: [String] = []

    private init() {
        ensureLogDirectory()
        writeSessionHeader()
    }

    public func log(_ message: String) {
        log(.info, category: "app", message)
    }

    public func log(_ level: Level, category: String, _ message: String) {
        let sanitized = sanitize(message)
        let line = formatLine(level: level, category: category, message: sanitized)
        appendToMemory(line)
        writeToFile(line)
        mirrorToUnifiedLogging(level: level, message: line)
    }

    public func logError(_ error: Error, context: String, category: String = "error") {
        log(.error, category: category, "[\(context)] \(error.localizedDescription)")
        if let localized = error as? LocalizedError, let reason = localized.failureReason {
            log(.error, category: category, "[\(context)] reason: \(reason)")
        }
    }

    public func clear() {
        logs.removeAll()
        fileQueue.sync {
            try? "".write(to: Self.logFileURL, atomically: true, encoding: .utf8)
        }
        writeSessionHeader()
    }

    public var allLogs: String {
        logs.joined(separator: "\n")
    }

    public func diagnosticReport(settingsSummary: String, userMessage: String) -> String {
        """
        ========================================
        MOVIEBOX DIAGNOSTIC REPORT
        ========================================
        Timestamp: \(isoFormatter.string(from: Date()))
        User message: \(userMessage)
        Log file: \(Self.logFileURL.path)

        --- CONFIGURATION ---
        \(settingsSummary)

        --- APPLICATION LOG ---
        \(allLogs.isEmpty ? "(no in-memory lines; see log file)" : allLogs)
        ========================================
        """
    }

    // MARK: - Private

    private func ensureLogDirectory() {
        try? FileManager.default.createDirectory(at: Self.logsDirectory, withIntermediateDirectories: true)
    }

    private func writeSessionHeader() {
        let header = """
        # MovieBox log — \(isoFormatter.string(from: Date()))
        # Path: \(Self.logFileURL.path)
        # Agents: read this file for runtime errors; see .agents/LOGGING.md
        ---
        """
        fileQueue.async { [header] in
            Self.appendLine(header, to: Self.logFileURL)
        }
    }

    private func formatLine(level: Level, category: String, message: String) -> String {
        let ts = isoFormatter.string(from: Date())
        return "[\(ts)] [\(level.rawValue)] [\(category)] \(message)"
    }

    private func sanitize(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func appendToMemory(_ line: String) {
        logs.append(line)
        if logs.count > Self.maxMemoryLines {
            logs.removeFirst(logs.count - Self.maxMemoryLines)
        }
    }

    private func writeToFile(_ line: String) {
        fileQueue.async {
            Self.rotateIfNeeded()
            Self.appendLine(line + "\n", to: Self.logFileURL)
        }
    }

    private nonisolated static func appendLine(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return
            }
        }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func rotateIfNeeded() {
        let url = logFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxFileBytes else { return }
        let backup = logsDirectory.appendingPathComponent("moviebox.log.1", isDirectory: false)
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    private func mirrorToUnifiedLogging(level: Level, message: String) {
        let escaped = message.replacingOccurrences(of: "%", with: "%%")
        switch level {
        case .debug:
            osLog.debug("\(escaped, privacy: .public)")
        case .info:
            osLog.info("\(escaped, privacy: .public)")
        case .warn:
            osLog.warning("\(escaped, privacy: .public)")
        case .error:
            osLog.error("\(escaped, privacy: .public)")
        }
        NSLog("MovieBox: %@", escaped)
    }
}
