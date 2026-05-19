import CoreTorrent
import Foundation

public struct StreamDiagnosticsSnapshot: Sendable {
    public struct Row: Identifiable, Sendable, Hashable {
        public let id: String
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.id = label
            self.label = label
            self.value = value
        }
    }

    public struct Section: Identifiable, Sendable, Hashable {
        public let id: String
        public let title: String
        public let rows: [Row]

        public init(title: String, rows: [Row]) {
            self.id = title
            self.title = title
            self.rows = rows
        }
    }

    public let sections: [Section]
    public let updatedAt: Date

    public init(sections: [Section], updatedAt: Date = .now) {
        self.sections = sections
        self.updatedAt = updatedAt
    }

    public static let empty = StreamDiagnosticsSnapshot(sections: [])
}

public enum StreamDiagnosticsFormatting {
    public static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 B" }
        let gb = Double(value) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(value) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(value) / 1024
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(value) B"
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.2f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    public static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", min(100, max(0, fraction * 100)))
    }
}
