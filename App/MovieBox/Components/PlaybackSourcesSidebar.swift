import CorePlayer
import CoreTorrent
import SwiftUI

/// In-player versions panel — matches episodes sidebar chrome and reuses torrent list rows.
struct PlaybackSourcesSidebar: View {
    @Bindable var playerState: PlayerState
    let torrents: [TorrentResult]

    private var qualitySections: [TorrentVersionSectionGroup] {
        TorrentCatalog.sections(from: torrents).map { section in
            TorrentVersionSectionGroup(
                id: section.id,
                title: section.title,
                models: section.variants.map(TorrentCardModel.init(torrent:))
            )
        }
    }

    private var selectedUUID: UUID? {
        guard let id = playerState.selectedPlaybackSourceID else { return nil }
        return UUID(uuidString: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Versions")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    playerState.isSourcesSidebarOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                TorrentVersionGroupedList(
                    sections: qualitySections,
                    mode: .player(
                        selectedTorrentID: selectedUUID,
                        isSwitching: playerState.isSwitchingSource,
                        onSelect: { torrentID in
                            guard let option = playerState.playbackSources.first(where: { $0.id == torrentID.uuidString }) else {
                                return
                            }
                            Task {
                                await playerState.onSelectPlaybackSource?(option)
                            }
                        }
                    ),
                    sectionHeaderColor: .white.opacity(0.55)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(12)
    }
}
