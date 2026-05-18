#if DEBUG
import CoreStorage
import Foundation
import SwiftData

/// Applies Rahul's deployed Worker + app token when Settings are still empty (local dev only).
enum DevelopmentSettings {
    /// Base URL only — health check is `{proxyBaseURL}/health`, API is `{proxyBaseURL}/api/...`
    static let proxyBaseURL = "https://moviebox-backend.rahulmarban.workers.dev"

    @MainActor
    static func applyIfNeeded(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let rows = try? modelContext.fetch(descriptor) else { return }

        let settings: AppSettings
        if let first = rows.first {
            settings = first
        } else {
            settings = AppSettings(defaultDownloadPath: "~/Movies/MovieBox")
            modelContext.insert(settings)
        }

        var changed = false
        if settings.proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.proxyBaseURL = proxyBaseURL
            changed = true
        }
        let trimmedToken = settings.appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            settings.appToken = DevelopmentSecrets.appToken
            changed = true
        }

        guard changed else { return }
        try? modelContext.save()
        NSLog("MovieBox: Applied development backend settings (\(proxyBaseURL))")
    }
}
#endif
