import SwiftUI
import CoreMetadata

public enum MovieBoxColors {
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let groupedBackground = Color(nsColor: .controlBackgroundColor)
    public static let panel = Color(nsColor: .controlBackgroundColor)
    public static let accent = Color(red: 0.98, green: 0.36, blue: 0.18)
    /// #007AFF — home tab ambient glow
    public static let homeGlow = Color(red: 0, green: 122 / 255, blue: 1)
    /// Warm amber — movies catalog glow
    public static let movieGlow = Color(red: 1, green: 0.58, blue: 0)
    /// Purple — shows catalog glow
    public static let showGlow = Color(red: 0.69, green: 0.32, blue: 0.87)
    public static let mutedText = Color.secondary
    public static let success = Color(red: 0.24, green: 0.72, blue: 0.45)
    public static let warning = Color(red: 0.95, green: 0.72, blue: 0.22)
    public static let danger = Color(red: 0.88, green: 0.25, blue: 0.22)
}

public enum MovieBoxTypography {
    public static let display = Font.system(.largeTitle, weight: .bold)
    public static let title = Font.system(.title2, weight: .semibold)
    public static let body = Font.system(.body)
    public static let caption = Font.system(.caption, weight: .medium)
}

/// Shared horizontal inset for home/catalog shelves so titles and carousels align.
public enum MovieBoxLayout {
    public static let shelfHorizontalInset: CGFloat = 28
    /// Wide cinematic shelf cards (home “Now In Theatres”, downloads).
    public static let landscapeCardWidth: CGFloat = 680
    public static let landscapeCardHeight: CGFloat = 382
    public static let landscapeCardCornerRadius: CGFloat = 14
    public static let landscapeLogoMaxWidth: CGFloat = 320
}

public enum GlassStrength {
    case ultraThin
    case regular
    /// Strongest fallback material; on macOS 26+ uses Liquid Glass `.regular` (no thicker Glass variant exists).
    case thick
}

public enum AdaptiveGlassShape: Sendable {
    case roundedRect(cornerRadius: CGFloat)
    case capsule
}

public struct AdaptiveGlass: ViewModifier {
    private let shape: AdaptiveGlassShape
    private let strength: GlassStrength

    public init(cornerRadius: CGFloat = 18, strength: GlassStrength = .regular) {
        self.shape = .roundedRect(cornerRadius: cornerRadius)
        self.strength = strength
    }

    public init(shape: AdaptiveGlassShape, strength: GlassStrength = .regular) {
        self.shape = shape
        self.strength = strength
    }

    public func body(content: Content) -> some View {
        switch shape {
        case .roundedRect(let cornerRadius):
            let rect = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            switch strength {
            case .ultraThin:
                content
                    .background(.ultraThinMaterial, in: rect)
                    .overlay { rect.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6) }
            case .regular:
                if #available(macOS 26.0, *) {
                    content.glassEffect(.regular.interactive(), in: rect)
                } else {
                    content
                        .background(.ultraThinMaterial, in: rect)
                        .overlay { rect.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6) }
                }
            case .thick:
                if #available(macOS 26.0, *) {
                    content.glassEffect(.regular.interactive(), in: rect)
                } else {
                    content
                        .background(.thickMaterial, in: rect)
                        .overlay { rect.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6) }
                }
            }
        case .capsule:
            let capsule = Capsule(style: .continuous)
            switch strength {
            case .ultraThin:
                content
                    .background(.ultraThinMaterial, in: capsule)
                    .overlay { capsule.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6) }
            case .regular:
                if #available(macOS 26.0, *) {
                    content.glassEffect(.regular.interactive(), in: capsule)
                } else {
                    content
                        .background(.ultraThinMaterial, in: capsule)
                        .overlay { capsule.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6) }
                }
            case .thick:
                if #available(macOS 26.0, *) {
                    content.glassEffect(.regular.interactive(), in: capsule)
                } else {
                    content
                        .background(.thickMaterial, in: capsule)
                        .overlay { capsule.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6) }
                }
            }
        }
    }
}

public extension View {
    func adaptiveGlass(cornerRadius: CGFloat = 18, strength: GlassStrength = .regular) -> some View {
        modifier(AdaptiveGlass(cornerRadius: cornerRadius, strength: strength))
    }

    func adaptiveGlass(shape: AdaptiveGlassShape, strength: GlassStrength = .regular) -> some View {
        modifier(AdaptiveGlass(shape: shape, strength: strength))
    }
}

/// Soft radial highlight anchored at the top-leading corner of a page.
public struct AmbientTopGlow: View {
    private let color: Color

    public init(color: Color) {
        self.color = color
    }

    public var body: some View {
        RadialGradient(
            colors: [color.opacity(0.12), Color.clear],
            center: .topLeading,
            startRadius: 20,
            endRadius: 480
        )
        .ignoresSafeArea()
    }
}

/// SF Symbol download control with a variable progress ring (`arrow.down.circle`).
public struct DownloadProgressIcon: View {
    public enum Mode: Equatable {
        case idle
        case queued
        case downloading(progress: Double)
        case paused(progress: Double)
    }

    public let mode: Mode
    public var size: CGFloat = 22

    /// Apple TV / system blue — used only while actively downloading.
    public static let activeRingColor = Color(red: 0, green: 122 / 255, blue: 1)

    public init(mode: Mode, size: CGFloat = 22) {
        self.mode = mode
        self.size = size
    }

    public var body: some View {
        Group {
            switch mode {
            case .idle:
                Image(systemName: "arrow.down.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            case .queued:
                variableSymbol(value: 0.08, useActiveBlue: false)
                    .symbolEffect(.pulse, options: .repeating)
            case .downloading(let progress):
                variableSymbol(value: progress, useActiveBlue: true)
            case .paused(let progress):
                variableSymbol(value: progress, useActiveBlue: false)
            }
        }
        .font(.system(size: size, weight: .medium))
        .frame(width: size + 4, height: size + 4)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func variableSymbol(value: Double, useActiveBlue: Bool) -> some View {
        let clamped = min(1, max(0.05, value))
        let symbol = Image(systemName: "arrow.down.circle", variableValue: clamped)
        if useActiveBlue {
            symbol
                .symbolRenderingMode(.palette)
                .foregroundStyle(Self.activeRingColor, Color.primary.opacity(0.22))
        } else {
            symbol
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .idle: "Download"
        case .queued: "Starting download"
        case .downloading(let progress): "Downloading \(Int(progress * 100)) percent"
        case .paused(let progress): "Paused at \(Int(progress * 100)) percent"
        }
    }
}

public struct GlassBadge: View {
    private let text: String
    private let color: Color

    public init(_ text: String, color: Color = MovieBoxColors.panel) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(MovieBoxTypography.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            // Pill always sizes to its content — never truncates ("108 mi…")
            // or wraps when squeezed inside a tight HStack.
            .fixedSize(horizontal: true, vertical: false)
    }
}

public struct GlassButton<Label: View>: View {
    private let action: () -> Void
    private let glassStrength: GlassStrength
    private let label: Label

    public init(
        action: @escaping () -> Void,
        glassStrength: GlassStrength = .regular,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.glassStrength = glassStrength
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            label
                .font(MovieBoxTypography.body.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .adaptiveGlass(cornerRadius: 14, strength: glassStrength)
    }
}

public struct MoviePosterCard: View {
    public static let posterWidth: CGFloat = 164
    public static let posterHeight: CGFloat = 246

    private let title: String
    private let subtitle: String
    private let posterURL: URL?
    /// Optional watch progress (0…1) shown as a thin bar on the poster bottom edge.
    private let progress: Double?
    private let action: () -> Void
    /// Optional hover callback — fired once when the cursor enters the card.
    /// Use it to kick off background prefetches (detail bundle, backdrop, etc.).
    private let onHover: (() -> Void)?

    public init(
        title: String,
        subtitle: String = "",
        posterURL: URL?,
        progress: Double? = nil,
        onHover: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.progress = progress
        self.onHover = onHover
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                poster
                    .frame(width: Self.posterWidth, height: Self.posterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, Color.black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0.001, progress < 0.995 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(.white.opacity(0.35))
                                    Capsule()
                                        .fill(.white)
                                        .frame(width: max(4, geo.size.width * progress))
                                }
                            }
                            .frame(height: 4)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                    }
                    .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 5)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .frame(width: Self.posterWidth, alignment: .leading)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: Self.posterWidth, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering, let onHover { onHover() }
        }
    }

    @ViewBuilder private var poster: some View {
        if let posterURL {
            CachedImageView(url: posterURL) {
                placeholder
            } content: { image in
                image.resizable().scaledToFill()
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(title.prefix(1))
                .font(.largeTitle.bold())
                .foregroundStyle(.secondary)
        }
    }
}

private struct IdentifiedShelfItem<Value>: Identifiable {
    let id: String
    let value: Value
}

public struct HorizontalMovieRow<Item: Identifiable, Content: View>: View {
    private let title: String
    private let items: [Item]
    private let itemIdentity: ((Item) -> String)?
    private let content: (Item) -> Content

    public init(
        title: String,
        items: [Item],
        itemIdentity: ((Item) -> String)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.title = title
        self.items = items
        self.itemIdentity = itemIdentity
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    if let itemIdentity {
                        ForEach(items.map { IdentifiedShelfItem(id: itemIdentity($0), value: $0) }) { entry in
                            content(entry.value)
                        }
                    } else {
                        ForEach(items) { item in
                            content(item)
                        }
                    }
                }
                .padding(.horizontal, MovieBoxLayout.shelfHorizontalInset)
                .padding(.bottom, 10)
            }
        }
    }
}

public struct LoadingShimmer: View {
    @State private var phase = false

    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay {
                LinearGradient(colors: [.clear, .primary.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                    .rotationEffect(.degrees(12))
                    .offset(x: phase ? 180 : -180)
            }
            .clipped()
            .task {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = true
                }
            }
    }
}

public enum BadgePalette {
    public static func hdrColor(label: String) -> Color {
        switch label {
        case "DV/HDR10", "Dolby Vision": Color(red: 0.36, green: 0.54, blue: 0.94)
        case "HDR10+": Color(red: 0.91, green: 0.63, blue: 0.13)
        case "HDR10", "HDR": Color(red: 0.24, green: 0.67, blue: 0.44)
        default: Color.gray
        }
    }

    public static func seedColor(_ seeders: Int) -> Color {
        switch seeders {
        case 501...: MovieBoxColors.success
        case 50...500: MovieBoxColors.warning
        case 10...49: .orange
        default: MovieBoxColors.danger
        }
    }

    public static func leechColor(_ leechers: Int) -> Color {
        switch leechers {
        case 50...: MovieBoxColors.danger
        case 10...49: .orange
        default: Color.secondary
        }
    }
}
