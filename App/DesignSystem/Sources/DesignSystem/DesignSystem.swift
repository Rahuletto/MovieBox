import SwiftUI

public enum MovieBoxColors {
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let groupedBackground = Color(nsColor: .controlBackgroundColor)
    public static let panel = Color(nsColor: .controlBackgroundColor)
    public static let accent = Color(red: 0.98, green: 0.36, blue: 0.18)
    public static let mutedText = Color.secondary
    public static let success = Color(red: 0.24, green: 0.72, blue: 0.45)
    public static let warning = Color(red: 0.95, green: 0.72, blue: 0.22)
    public static let danger = Color(red: 0.88, green: 0.25, blue: 0.22)
}

public enum MovieBoxTypography {
    public static let display = Font.system(.largeTitle, design: .rounded, weight: .bold)
    public static let title = Font.system(.title2, design: .rounded, weight: .semibold)
    public static let body = Font.system(.body, design: .rounded)
    public static let caption = Font.system(.caption, design: .rounded, weight: .medium)
}

public struct AdaptiveGlass: ViewModifier {
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 18) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.6)
                }
        }
    }
}

public extension View {
    func adaptiveGlass(cornerRadius: CGFloat = 18) -> some View {
        modifier(AdaptiveGlass(cornerRadius: cornerRadius))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

public struct GlassButton<Label: View>: View {
    private let action: () -> Void
    private let label: Label

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
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
        .adaptiveGlass(cornerRadius: 14)
    }
}

public struct MoviePosterCard: View {
    private let title: String
    private let subtitle: String
    private let posterURL: URL?
    private let action: () -> Void

    public init(title: String, subtitle: String = "", posterURL: URL?, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                poster
                    .frame(width: 150, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, Color.primary.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .shadow(color: Color.primary.opacity(0.1), radius: 10, x: 0, y: 4)

                Text(title)
                    .font(MovieBoxTypography.caption)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .frame(width: 150, alignment: .leading)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var poster: some View {
        if let posterURL {
            AsyncImage(url: posterURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    LoadingShimmer()
                @unknown default:
                    placeholder
                }
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

public struct HorizontalMovieRow<Item: Identifiable, Content: View>: View {
    private let title: String
    private let items: [Item]
    private let content: (Item) -> Content

    public init(title: String, items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.title = title
        self.items = items
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, 28)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(items) { item in
                        content(item)
                    }
                }
                .padding(.horizontal, 28)
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
}
