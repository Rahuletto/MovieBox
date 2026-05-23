import CorePlayer
import SwiftUI

/// In-player subtitles panel — mirrors versions sidebar chrome.
struct PlaybackSubtitlesSidebar: View {
    @Bindable var playerState: PlayerState

    private var embeddedOptions: [PlayerSubtitleOption] {
        playerState.availableSubtitles.filter(\.isEmbedded)
    }

    private var remoteSections: [(language: String, items: [PlayerSubtitleOption])] {
        let remote = playerState.availableSubtitles.filter { !$0.isEmbedded }
        let grouped = Dictionary(grouping: remote) { option in
            option.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return grouped
            .map { (language: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                if lhs.language == rhs.language { return false }
                if lhs.language == "english" { return true }
                if rhs.language == "english" { return false }
                return lhs.language.localizedCaseInsensitiveCompare(rhs.language) == .orderedAscending
            }
    }

    private var catalogLoadingProgress: SubtitleLoadProgress {
        SubtitleLoadProgress(title: "Searching subtitles", detail: "Querying providers…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Subtitles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Toggle("", isOn: subtitlesEnabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(playerState.areSubtitlesEnabled ? "Turn subtitles off" : "Turn subtitles on")
                Button {
                    playerState.isSubtitlesSidebarOpen = false
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

            if playerState.isLoadingSubtitleCatalog {
                subtitleProgressPanel(catalogLoadingProgress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let progress = playerState.subtitleLoadProgress, playerState.availableSubtitles.isEmpty {
                subtitleProgressPanel(progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playerState.availableSubtitles.isEmpty {
                VStack(spacing: 12) {
                    Text("No subtitles found.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                    if playerState.onRefreshSubtitles != nil {
                        Button("Search again") {
                            Task { await playerState.onRefreshSubtitles?() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let progress = playerState.subtitleLoadProgress {
                        subtitleProgressPanel(progress)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if !embeddedOptions.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("In video")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .textCase(.uppercase)

                                    ForEach(embeddedOptions) { option in
                                        subtitleRow(option)
                                    }
                                }
                            }

                            ForEach(remoteSections, id: \.language) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(sectionTitle(for: section.language))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .textCase(.uppercase)

                                    ForEach(section.items) { option in
                                        subtitleRow(option)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(12)
        .task {
            guard playerState.availableSubtitles.isEmpty,
                  playerState.onRefreshSubtitles != nil,
                  !playerState.isLoadingSubtitleCatalog else { return }
            await playerState.onRefreshSubtitles?()
        }
    }

    private func subtitleProgressPanel(_ progress: SubtitleLoadProgress) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
                .tint(.white)
            VStack(spacing: 4) {
                Text(progress.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let detail = progress.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private func sectionTitle(for language: String) -> String {
        if !embeddedOptions.isEmpty {
            return "Download · \(language.capitalized)"
        }
        return language.capitalized
    }

    private var subtitlesEnabledBinding: Binding<Bool> {
        Binding(
            get: { playerState.areSubtitlesEnabled },
            set: { playerState.setSubtitlesEnabled($0) }
        )
    }

    @ViewBuilder
    private func subtitleRow(_ option: PlayerSubtitleOption) -> some View {
        let isSelected = playerState.selectedSubtitleID == option.id
        let isLoadingThisRow = isSelected && playerState.subtitleLoadProgress != nil
        Button {
            Task { await playerState.onSelectSubtitle?(option) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if isLoadingThisRow {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .frame(width: 14, height: 14)
                            .padding(.top, 2)
                    } else {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : (option.isEmbedded ? "film" : "text.bubble"))
                            .font(.system(size: 14))
                            .foregroundStyle(isSelected ? Color.green : Color.white.opacity(0.7))
                            .padding(.top, 2)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if isLoadingThisRow, let detail = playerState.subtitleLoadProgress?.title {
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    } else {
                        Text(option.isEmbedded ? "Embedded in file" : "by \(option.author)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoadingThisRow)
    }
}
