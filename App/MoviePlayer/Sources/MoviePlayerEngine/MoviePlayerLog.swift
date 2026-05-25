import CoreStorage
import Foundation

enum MoviePlayerLog {
    static func info(_ message: String) {
        MovieBoxFileLogger.log(.info, category: "movieplayer", message)
    }

    static func warn(_ message: String) {
        MovieBoxFileLogger.log(.warn, category: "movieplayer", message)
    }

    static func error(_ message: String) {
        MovieBoxFileLogger.log(.error, category: "movieplayer", message)
    }
}
