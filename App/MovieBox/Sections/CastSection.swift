import SwiftUI
import DesignSystem
import CoreMetadata

struct CastSection: View {
    let cast: [CastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(cast) { member in
                        VStack(spacing: 6) {
                            if let path = member.profilePath, let url = URL(string: "https://image.tmdb.org/t/p/w185\(path)") {
                                CachedImageView(url: url) {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.secondary)
                                } content: { image in
                                    image.resizable().scaledToFill()
                                }
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .frame(width: 80, height: 80)
                                    .overlay {
                                        Image(systemName: "person.circle.fill")
                                            .font(.system(size: 32))
                                            .foregroundStyle(.secondary)
                                    }
                            }

                            Text(member.name)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .frame(width: 80)

                            Text(member.character)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 80)
                        }
                    }
                }
                .padding(.trailing, 100)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
