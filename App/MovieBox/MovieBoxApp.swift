import SwiftUI
import CorePlayer
import CoreStorage
import CoreMetadata
import SwiftData

@main
struct MovieBoxApp: App {
    @State private var router = AppRouter()
    @State private var playerState = PlayerState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(playerState)
                .modelContainer(for: MovieBoxSchema.models)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
                .modelContainer(for: MovieBoxSchema.models)
        }
    }
}
