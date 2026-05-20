import SwiftUI
import DesignSystem
import CoreMetadata

struct CastSection: View {
    let cast: [CastMember]
    var onSelectMember: ((CastMember) -> Void)? = nil

    private let photoSize: CGFloat = 128
    private let cardWidth: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cast & Crew")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)
                .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)

            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ForEach(cast) { member in
                        Button {
                            onSelectMember?(member)
                        } label: {
                            VStack(spacing: 6) {
                                castPhoto(for: member)
                                Text(member.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: cardWidth)

                                Text(member.character)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: cardWidth)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(onSelectMember == nil)
                    }
                }
                .padding(.horizontal, DetailLayoutMetrics.shelfSideInset)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func castPhoto(for member: CastMember) -> some View {
        if let path = member.profilePath,
           let url = MetadataClient().imageURL(path: path, width: 342) {
            CachedImageView(url: url) {
                photoPlaceholder
            } content: { image in
                image.resizable().scaledToFill()
            }
            .frame(width: photoSize, height: photoSize)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            photoPlaceholder
        }
    }

    private var photoPlaceholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(white: 0.12))
            .frame(width: photoSize, height: photoSize)
            .overlay {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
            }
    }
}
