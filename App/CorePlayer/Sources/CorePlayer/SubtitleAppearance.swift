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
    let fontSize: CGFloat
    let isVisible: Bool

    public init(
        text: String,
        cueID: UUID?,
        appearance: SubtitleAppearance,
        fontSize: CGFloat = 20,
        isVisible: Bool
    ) {
        self.text = text
        self.cueID = cueID
        self.appearance = appearance
        self.fontSize = fontSize
        self.isVisible = isVisible
    }

    public var body: some View {
        VStack {
            Spacer()
            if isVisible, !text.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    styledText(text)
                        .id(subtitleIdentity)
                    Spacer(minLength: 48)
                }
                .padding(.bottom, 110)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                .animation(.easeOut(duration: 0.2), value: cueID)
                .animation(.easeOut(duration: 0.2), value: appearance)
                .animation(.easeOut(duration: 0.2), value: fontSize)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isVisible)
    }

    private var subtitleIdentity: String {
        "\(cueID?.uuidString ?? "none")-\(appearance.rawValue)-\(fontSize)"
    }

    @ViewBuilder
    private func styledText(_ text: String) -> some View {
        switch appearance {
        case .cinematic:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .fixedSize(horizontal: true, vertical: true)
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 10, y: 3)

        case .largeWhite:
            Text(text)
                .font(.system(size: fontSize * 1.25, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 6, y: 2)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: true, vertical: true)

        case .yellowBlack:
            Text(text)
                .font(.system(size: fontSize * 1.05, weight: .bold))
                .foregroundStyle(.yellow)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize(horizontal: true, vertical: true)

        case .system:
            Text(text)
                .font(.system(size: fontSize * 1.05, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 4, y: 2)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: true, vertical: true)
        }
    }
}
