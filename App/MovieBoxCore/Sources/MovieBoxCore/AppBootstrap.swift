import CoreStorage
import CoreStreaming
import SwiftData

@MainActor
public enum AppBootstrap {
    public static func runInitialSetup(
        modelContext: ModelContext,
        errorCenter: AppErrorCenter,
        appServices: AppServices,
        didAttachPersistence: inout Bool
    ) {
        LogStore.shared.log("AppBootstrap: Application launched.")

        if !didAttachPersistence {
            let persistence = DownloadPersistenceService(modelContext: modelContext, errorCenter: errorCenter)
            persistence.attach(to: appServices.downloadManager)
            appServices.downloadPersistence = persistence
            appServices.playbackCoordinator.downloadPersistence = persistence
            didAttachPersistence = true
        }

        seedSettingsIfNeeded(modelContext: modelContext, errorCenter: errorCenter)
    }

    private static func seedSettingsIfNeeded(modelContext: ModelContext, errorCenter: AppErrorCenter) {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let existing = try? modelContext.fetch(descriptor) else { return }

        if existing.isEmpty {
            LogStore.shared.log("AppBootstrap: Inserting default AppSettings.")
            modelContext.insert(AppSettings(
                proxyBaseURL: "",
                appToken: "",
                tmdbBearerToken: "",
                omdbAPIKey: "",
                defaultDownloadPath: "~/Movies/MovieBox"
            ))
            modelContext.saveOrReport(errorCenter, context: "Default settings")
            return
        }

        guard let first = existing.first else { return }
        LogStore.shared.log("AppBootstrap: Loaded AppSettings.")
        if first.defaultDownloadPath == "~/Downloads/MovieBox" || first.defaultDownloadPath.isEmpty {
            first.defaultDownloadPath = "~/Movies/MovieBox"
            modelContext.saveOrReport(errorCenter, context: "Download path migration")
        }
    }
}
