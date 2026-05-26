import AppKit
import CoreMetadata
import CorePlayer
import CoreStorage
import CoreStreaming
import MovieBoxCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@main
struct MovieBoxApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    private let sharedModelContainer: ModelContainer

    @State private var router = AppRouter()
    @State private var playerState = PlayerState()
    @State private var appServices = AppServices()
    @State private var errorCenter = AppErrorCenter()
    @State private var importErrorMessage: String?
    @State private var didConfigurePersistence = false
    @Query private var settings: [AppSettings]

    init() {
        do {
            sharedModelContainer = try MovieBoxModelContainer.make()
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    private func wireAppDelegate() {
        appDelegate.appServices = appServices
        appServices.downloadManager.onTasksUpdated = { [appServices] in
            DockDownloadPresenter.update(tasks: appServices.downloadManager.tasks)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(playerState)
                .environment(appServices)
                .environment(errorCenter)
                .modelContainer(sharedModelContainer)
                .onAppear { wireAppDelegate() }
                .onChange(of: playerState.isPresented) { _, presented in
                    if !presented, playerState.isStreamingTorrent {
                        Task { await appServices.cancelActiveStream() }
                    }
                }
                .onOpenURL { url in
                    do {
                        try MagnetImportHandler.handle(url: url, router: router)
                    } catch {
                        importErrorMessage = error.localizedDescription
                    }
                }
                .alert(
                    "Could Not Import",
                    isPresented: Binding(
                        get: { importErrorMessage != nil },
                        set: { if !$0 { importErrorMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { importErrorMessage = nil }
                } message: {
                    Text(importErrorMessage ?? "")
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1440, height: 900)
        .commands {
            AppMenuCommands(
                router: router,
                playerState: playerState,
                openMagnetPanel: openMagnetImportPanel,
                copyDiagnostics: { copyDiagnosticReportToPasteboard() }
            )
        }

        Settings {
            SettingsView()
                .modelContainer(sharedModelContainer)
                .environment(appServices)
        }
    }

    private func copyDiagnosticReportToPasteboard() {
        DiagnosticsReport.copyToPasteboard(
            userMessage: "User-requested diagnostic copy",
            settings: settings.first
        )
    }

    private func openMagnetImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Magnet or Torrent"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.message = "Choose a .torrent file. For magnet links, paste them on the Downloads tab or open a magnet: link from your browser."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MagnetImportHandler.handle(url: url, router: router)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }
}
