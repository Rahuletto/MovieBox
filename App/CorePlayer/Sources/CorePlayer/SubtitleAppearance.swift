import SwiftUI

/// Visual style for on-screen subtitles (Settings → Playback → Subtitle Style).
public enum SubtitleAppearance: String, Sendable, CaseIterable {
    case cinematic = "cinematic"
    case system = "system"
    case largeWhite = "large-white"
    case yellowBlack = "yellow-black"

    public static func from(settingsValue: String) -> SubtitleAppearance {
        SubtitleAppearance(rawValue: settingsValue) ?? .cinematic
    }

    public var displayName: String {
        switch self {
        case .cinematic: "Cinematic (pill)"
        case .system: "System default"
        case .largeWhite: "Large white"
        case .yellowBlack: "Yellow on black"
        }
    }
}

// MARK: - Overlay

public struct SubtitleOverlayView: View {
    let text: String
    let cueID: UUID?
    let appearance: SubtitleAppearance
    let isVisible: Bool

    public init(text: String, cueID: UUID?, appearance: SubtitleAppearance, isVisible: Bool) {
        self.text = text
        self.cueID = cueID
        self.appearance = appearance
        self.isVisible = isVisible
    }

    public var body: some View {
        VStack {
            Spacer()
            if isVisible, !text.isEmpty {
                styledText(text)
                    .id(subtitleIdentity)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 110)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .animation(.easeOut(duration: 0.2), value: cueID)
                    .animation(.easeOut(duration: 0.2), value: appearance)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isVisible)
    }

    private var subtitleIdentity: String {
        "\(cueID?.uuidString ?? "none")-\(appearance.rawValue)"
    }

    @ViewBuilder
    private func styledText(_ text: String) -> some View {
        switch appearance {
        case .cinematic:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                Text(text)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 10, y: 3)

        case .largeWhite:
            Text(text)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 6, y: 2)
                .multilineTextAlignment(.center)

        case .yellowBlack:
            Text(text)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .multilineTextAlignment(.center)

        case .system:
            Text(text)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 4, y: 2)
                .multilineTextAlignment(.center)
        }
    }
}
