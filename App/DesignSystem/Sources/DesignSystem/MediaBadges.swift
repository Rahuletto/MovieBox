import SwiftUI

// MARK: - Apple TV–style metadata badges

/// Outlined capsule used for ratings (U/A 16+), CC, SDH, AD.
public struct MediaOutlineBadge: View {
    private let text: String
    private let foreground: Color
    private let stroke: Color

    public init(_ text: String, foreground: Color = .primary, stroke: Color? = nil) {
        self.text = text
        self.foreground = foreground
        self.stroke = stroke ?? foreground.opacity(0.55)
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Small filled tag for 4K and similar technical labels.
public struct MediaFilledBadge: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.22), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Year · runtime · rating · tech badges in one row (Apple TV detail style).
public struct MediaMetadataRibbon<Tech: View>: View {
    public let year: String?
    public let runtimeMinutes: Int?
    public let contentRating: String?
    public let accessibilityTags: [String]
    public let labelColor: Color
    public let outlineForeground: Color
    public let outlineStroke: Color
    @ViewBuilder private let techBadges: () -> Tech

    public init(
        year: String? = nil,
        runtimeMinutes: Int? = nil,
        contentRating: String? = nil,
        accessibilityTags: [String] = [],
        labelColor: Color = .secondary,
        outlineForeground: Color = .primary,
        outlineStroke: Color? = nil,
        @ViewBuilder techBadges: @escaping () -> Tech
    ) {
        self.year = year
        self.runtimeMinutes = runtimeMinutes
        self.contentRating = contentRating
        self.accessibilityTags = accessibilityTags
        self.labelColor = labelColor
        self.outlineForeground = outlineForeground
        self.outlineStroke = outlineStroke ?? outlineForeground.opacity(0.55)
        self.techBadges = techBadges
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let year, !year.isEmpty {
                Text(year)
                    .font(.subheadline)
                    .foregroundStyle(labelColor)
            }

            if let runtimeMinutes, runtimeMinutes > 0 {
                if year != nil {
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(labelColor.opacity(0.7))
                }
                Text("\(runtimeMinutes) min")
                    .font(.subheadline)
                    .foregroundStyle(labelColor)
            }

            if let contentRating, !contentRating.isEmpty {
                MediaOutlineBadge(
                    contentRating,
                    foreground: outlineForeground,
                    stroke: outlineStroke
                )
            }

            techBadges()

            ForEach(accessibilityTags, id: \.self) { tag in
                MediaOutlineBadge(
                    tag,
                    foreground: outlineForeground,
                    stroke: outlineStroke
                )
            }
        }
        .lineLimit(1)
    }
}

/// "Starring …" line aligned to the hero's right side.
public struct MediaStarringLine: View {
    public let names: [String]
    public let maxNames: Int
    public let labelColor: Color
    public let nameColor: Color

    public init(
        names: [String],
        maxNames: Int = 3,
        labelColor: Color = .secondary,
        nameColor: Color = .primary
    ) {
        self.names = names
        self.maxNames = maxNames
        self.labelColor = labelColor
        self.nameColor = nameColor
    }

    public var body: some View {
        if names.isEmpty {
            EmptyView()
        } else {
            (
                Text("Starring ")
                    .foregroundStyle(labelColor)
                + Text(names.prefix(maxNames).joined(separator: ", "))
                    .foregroundStyle(nameColor)
            )
            .font(.subheadline)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 320, alignment: .trailing)
        }
    }
}
