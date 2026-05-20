import CoreMetadata
import DesignSystem
import SwiftUI

struct PersonHeroHeader: View {
    let profile: PersonProfile
    @Binding var isBiographyExpanded: Bool

    private let photoSize: CGFloat = 160

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            profilePhoto

            VStack(alignment: .leading, spacing: 12) {
                Text(profile.name)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 2)

                HStack(spacing: 8) {
                    if let department = profile.knownForDepartment, !department.isEmpty {
                        GlassBadge(department, color: MovieBoxColors.accent.opacity(0.85))
                    }
                    if let ageLine = profile.displayAgeLine {
                        Text(ageLine)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }

                if let birthplace = profile.placeOfBirth, !birthplace.isEmpty {
                    Label(birthplace, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }

                if !profile.biography.isEmpty {
                    biographyBlock
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var profilePhoto: some View {
        if let path = profile.profilePath,
           let url = MetadataClient().imageURL(path: path, width: 342) {
            CachedImageView(url: url) {
                photoPlaceholder
            } content: { image in
                image.resizable().scaledToFill()
            }
            .frame(width: photoSize, height: photoSize)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
        } else {
            photoPlaceholder
        }
    }

    private var photoPlaceholder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(white: 0.15))
            .frame(width: photoSize, height: photoSize)
            .overlay {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.35))
            }
    }

    private var biographyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profile.biography)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(isBiographyExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            if profile.biography.count > 200 {
                Button(isBiographyExpanded ? "Show less" : "Read more") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isBiographyExpanded.toggle()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .buttonStyle(.plain)
            }
        }
    }
}
