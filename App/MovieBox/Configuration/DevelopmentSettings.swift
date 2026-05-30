#if DEBUG
import CoreStorage
import Foundation
import MovieBoxCore
import SwiftData

/// Debug-only: pre-fills the maintainer's personal Worker URL + token when Settings are empty.
enum DevelopmentSettings {
    /// Personal Worker — not a public service; self-host for your own use.
    static let proxyBaseURL = BackendProxyURL.production

    @MainActor
    static func applyIfNeeded(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let rows = try? modelContext.fetch(descriptor) else { return }

        let settings: AppSettings
        if let first = rows.first {
            settings = first
        } else {
            settings = AppSettings(defaultDownloadPath: "")
            modelContext.insert(settings)
        }

        var changed = false
        if settings.proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.proxyBaseURL = proxyBaseURL
            settings.useLocalBackend = false
            changed = true
        }
        // Older builds pointed at production URL but still routed API calls to localhost.
        if settings.useLocalBackend,
           settings.proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) == proxyBaseURL {
            settings.useLocalBackend = false
            changed = true
        }
        let trimmedToken = settings.appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            settings.appToken = DevelopmentSecrets.appToken
            changed = true
        }

        guard changed else { return }
        try? modelContext.save()
        let endpoint = settings.useLocalBackend ? BackendProxyURL.local : settings.proxyBaseURL
        NSLog("MovieBox: Applied development backend settings (\(endpoint))")
    }
}
#endif
