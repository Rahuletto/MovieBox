import SwiftUI

public enum SubtitleAppearance: String, Sendable, CaseIterable {
    case modern = "modern"
    case system = "system"
    case largeWhite = "large-white"
    case yellowBlack = "yellow-black"

    public static func from(settingsValue: String) -> SubtitleAppearance {
        if settingsValue == "cinematic" { return .modern }
        return SubtitleAppearance(rawValue: settingsValue) ?? .modern
    }

    public var displayName: String {
        switch self {
        case .modern: "Modern"
        case .system: "System default"
        case .largeWhite: "Large white"
        case .yellowBlack: "Yellow on black"
        }
    }
}

// MARK: - Load progress

public struct SubtitleLoadProgress: Sendable, Equatable {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

// MARK: - Overlay

public struct SubtitleOverlayView: View {
    let text: String
    let cueID: UUID?
    let appearance: SubtitleAppearance
    let fontSize: CGFloat
    let isVisible: Bool
    let showsControls: Bool
    let loadProgress: SubtitleLoadProgress?

    private let restingBottomInset: CGFloat = 48
    private let elevatedBottomInset: CGFloat = 138

    public init(
        text: String,
        cueID: UUID?,
        appearance: SubtitleAppearance,
        fontSize: CGFloat = 20,
        isVisible: Bool,
        showsControls: Bool = false,
        loadProgress: SubtitleLoadProgress? = nil
    ) {
        self.text = text
        self.cueID = cueID
        self.appearance = appearance
        self.fontSize = fontSize
        self.isVisible = isVisible
        self.showsControls = showsControls
        self.loadProgress = loadProgress
    }

    private var subtitleBottomInset: CGFloat {
        showsControls ? elevatedBottomInset : restingBottomInset
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            if isVisible {
                HStack {
                    Spacer(minLength: 48)
                    Group {
                        if !text.isEmpty {
                            styledText(text)
                                .frame(maxWidth: 720)
                                .fixedSize(horizontal: true, vertical: true)
                        } else if let loadProgress {
                            subtitleLoadingPill(loadProgress)
                        }
                    }
                    .id(subtitleIdentity)
                    .transition(.opacity)
                    .allowsHitTesting(true)
                    Spacer(minLength: 48)
                }
                .padding(.bottom, subtitleBottomInset)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.22), value: showsControls)
        .animation(.easeOut(duration: 0.18), value: isVisible)
        .animation(.easeOut(duration: 0.12), value: subtitleIdentity)
    }

    private func subtitleLoadingPill(_ progress: SubtitleLoadProgress) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.title)
                    .font(.system(size: fontSize * 0.72, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                if let detail = progress.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: fontSize * 0.58, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }

    private var subtitleIdentity: String {
        "\(cueID?.uuidString ?? "none")-\(appearance.rawValue)-\(fontSize)"
    }

    @ViewBuilder
    private func styledText(_ text: String) -> some View {
        switch appearance {
        case .modern:
            FluidSubtitleLabel(
                text: text,
                font: .system(size: fontSize, weight: .semibold, design: .rounded),
                foreground: .white,
                horizontalPadding: 14,
                verticalPadding: 8,
                cornerRadius: 10,
                lineSpacing: 3,
                background: .ultraThinMaterial
            )

        case .largeWhite:
            Text(text)
                .font(.system(size: fontSize * 1.25, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 6, y: 2)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)

        case .yellowBlack:
            FluidSubtitleLabel(
                text: text,
                font: .system(size: fontSize * 1.05, weight: .bold),
                foreground: .yellow,
                horizontalPadding: 12,
                verticalPadding: 6,
                cornerRadius: 8,
                lineSpacing: 2,
                solidBackground: .black
            )

        case .system:
            Text(text)
                .font(.system(size: fontSize * 1.05, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 4, y: 2)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
        }
    }
}

// MARK: - Fluid subtitle background

private struct FluidSubtitleLabel: View {
    let text: String
    let font: Font
    let foreground: Color
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
    let lineSpacing: CGFloat
    var background: Material? = nil
    var solidBackground: Color? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let solidBackground {
                captionText
                    .background(solidBackground, in: shape)
            } else if let background {
                captionText
                    .background(background, in: shape)
            } else {
                captionText
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(solidBackground == nil ? 0.35 : 0), radius: 10, y: 3)
    }

    private var captionText: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .center)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
    }
}
