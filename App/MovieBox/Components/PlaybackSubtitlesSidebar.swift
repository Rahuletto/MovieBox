import CorePlayer
import SwiftUI

/// In-player subtitles panel — mirrors versions sidebar chrome.
struct PlaybackSubtitlesSidebar: View {
    @Bindable var playerState: PlayerState

    private var languageSections: [(language: String, items: [PlayerSubtitleOption])] {
        let grouped = Dictionary(grouping: playerState.availableSubtitles) { option in
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
                ProgressView()
                    .controlSize(.small)
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(languageSections, id: \.language) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.language.capitalized)
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
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(12)
        .task {
            if playerState.availableSubtitles.isEmpty {
                await playerState.onRefreshSubtitles?()
            }
        }
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
        Button {
            Task { await playerState.onSelectSubtitle?(option) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "text.bubble")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.green : Color.white.opacity(0.7))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("by \(option.author)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
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
    }
}
