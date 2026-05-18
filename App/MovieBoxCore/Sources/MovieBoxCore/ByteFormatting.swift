import Foundation

public enum ByteFormatting {
    public static func buffered(_ bytes: Int64) -> String {
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB buffered", Double(bytes) / 1_048_576)
        }
        if bytes >= 1024 {
            return String(format: "%.0f KB buffered", Double(bytes) / 1024)
        }
        return "\(bytes) B buffered"
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}
