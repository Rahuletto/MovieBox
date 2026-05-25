import AppKit
import CorePlayer
import MovieBoxCore
import SwiftUI
import UniformTypeIdentifiers

/// macOS menu bar commands for MovieBox.
struct AppMenuCommands: Commands {
    @Bindable var router: AppRouter
    var playerState: PlayerState
    var openMagnetPanel: () -> Void
    var copyDiagnostics: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .newItem) {
            Button("Open Magnet Link or Torrent File…") {
                openMagnetPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Go to Downloads") {
                router.show(.downloads)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandMenu("View") {
            Button("Home") { router.show(.home) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Movies") { router.show(.movies) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Shows") { router.show(.tvShows) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Library") { router.show(.library) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Downloads") { router.show(.downloads) }
                .keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("Search") { router.show(.search) }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Playback") {
            Button(playerState.isPlaying ? "Pause" : "Play") {
                playerState.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!playerState.isPresented)

            Button("Stop Playback") {
                playerState.dismiss()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!playerState.isPresented)

            Divider()

            Button("Toggle Full Screen") {
                playerState.toggleFullScreen()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .disabled(!playerState.isPresented)

            Button("Picture in Picture") {
                playerState.togglePictureInPicture()
            }
            .disabled(!playerState.isPresented)

            Button("Toggle Subtitles") {
                playerState.toggleSubtitle()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!playerState.isPresented)

            Divider()

            Button("Next Episode") {
                playerState.playNextEpisode()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!playerState.isPresented || playerState.currentEpisodeIndex == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Back") {
                if playerState.isPresented {
                    playerState.dismiss()
                } else if router.isShowingDetail {
                    router.backFromDetail()
                }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!playerState.isPresented && !router.isShowingDetail)

            Button("Close") {
                if playerState.isPresented {
                    playerState.dismiss()
                } else if router.isShowingDetail {
                    router.backFromDetail()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!playerState.isPresented && !router.isShowingDetail)
        }

        CommandMenu("Help") {
            Button("Open Log File") {
                LogFileActions.openLogFile()
            }
            Button("Reveal Logs in Finder") {
                LogFileActions.revealLogsDirectory()
            }
            Divider()
            Button("Copy Diagnostic Report") {
                copyDiagnostics()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

enum LogFileActions {
    static func openLogFile() {
        let url = LogStore.logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            LogStore.shared.log(.info, category: "app", "Creating log file before open.")
        }
        NSWorkspace.shared.open(url)
    }

    static func revealLogsDirectory() {
        NSWorkspace.shared.open(LogStore.logsDirectory)
    }
}
