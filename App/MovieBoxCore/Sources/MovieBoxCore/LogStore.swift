import CoreStorage
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
    public nonisolated static var logFileURL: URL { MovieBoxFileLogger.logFileURL }

    /// macOS standard log directory: `~/Library/Logs/MovieBox/`
    public nonisolated static var logsDirectory: URL { MovieBoxFileLogger.logsDirectory }

    private static let maxMemoryLines = 2_000

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
        writeToFile(level: level, category: category, message: sanitized)
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
        MovieBoxFileLogger.appendRaw(header)
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

    private func writeToFile(level: Level, category: String, message: String) {
        let fileLevel: MovieBoxFileLogger.Level = switch level {
        case .debug: .debug
        case .info: .info
        case .warn: .warn
        case .error: .error
        }
        MovieBoxFileLogger.log(fileLevel, category: category, message)
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
