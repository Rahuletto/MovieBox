import AppKit
import CoreStorage
import Foundation
import MovieBoxCore

enum DiagnosticsReport {
    static func settingsSummary(from settings: AppSettings?) -> String {
        let downloadPath = (settings?.defaultDownloadPath as NSString?)?.expandingTildeInPath ?? ""
        return """
        Use Local Backend: \(settings?.useLocalBackend == true ? "Yes" : "No")
        Proxy Base URL: \(settings?.resolvedProxyBaseURL ?? "Not Configured")
        Default Download Path: \(settings?.defaultDownloadPath ?? "Not Configured")
        Preferred Quality: \(settings?.preferredQuality ?? "Not Configured")
        Metadata Mode: \(String(describing: settings?.metadataMode))
        Debug Logging: \(settings?.debugLogging == true ? "Yes" : "No")
        Can Write Downloads Folder: \(FileManager.default.isWritableFile(atPath: downloadPath) ? "Yes" : "No")
        Log file: \(LogStore.logFileURL.path)
        """
    }

    static func copyToPasteboard(userMessage: String, settings: AppSettings?) {
        let report = LogStore.shared.diagnosticReport(
            settingsSummary: settingsSummary(from: settings),
            userMessage: userMessage
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
