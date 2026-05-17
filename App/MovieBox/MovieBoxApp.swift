import AppKit
import SwiftUI
import CorePlayer
import CoreStorage
import CoreMetadata
import SwiftData
import UniformTypeIdentifiers

@main
struct MovieBoxApp: App {
    private let sharedModelContainer: ModelContainer

    @State private var router = AppRouter()
    @State private var playerState = PlayerState()
    @State private var importErrorMessage: String?

    init() {
        do {
            sharedModelContainer = try MovieBoxModelContainer.make()
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(playerState)
                .modelContainer(sharedModelContainer)
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
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open Magnet Link or Torrent File…") {
                    openMagnetImportPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Home") { router.show(.home) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("TV Shows") { router.show(.tvShows) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Movies") { router.show(.movies) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Library") { router.show(.library) }
                    .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("Search") { router.show(.search) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .modelContainer(sharedModelContainer)
        }
    }

    private func openMagnetImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Magnet or Torrent"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let torrentType = UTType(filenameExtension: "torrent") {
            panel.allowedContentTypes = [torrentType]
        } else {
            panel.allowedFileTypes = ["torrent"]
        }
        panel.message = "Choose a .torrent file. For magnet links, paste them on the Downloads tab or open a magnet: link from your browser."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MagnetImportHandler.handle(url: url, router: router)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }
}
