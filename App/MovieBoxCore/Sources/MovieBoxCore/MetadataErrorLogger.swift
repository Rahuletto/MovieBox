import Foundation

public enum MetadataErrorLogger {
    @MainActor
    public static func record(_ error: Error, context: String, category: String = "metadata") {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return
        }
        LogStore.shared.logError(error, context: context, category: category)
        let frames = Thread.callStackSymbols.prefix(6).joined(separator: "\n")
        LogStore.shared.log(.debug, category: category, "Stack (truncated):\n\(frames)")
    }

    public static func userMessage(for error: Error, backendURL: String? = nil) -> String {
        let base = error.localizedDescription
        guard let backendURL, !backendURL.isEmpty else { return base }
        if let urlError = error as? URLError,
           urlError.code == .secureConnectionFailed || urlError.code == .cannotConnectToHost
        {
            return "\(base)\n\nBackend: \(backendURL)\nCheck /health in a browser, then Settings → Metadata."
        }
        return base
    }
}
