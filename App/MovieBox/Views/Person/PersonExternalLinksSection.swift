import CoreMetadata
import DesignSystem
import SwiftUI

struct PersonExternalLinksSection: View {
    let profile: PersonProfile
    let links: PersonExternalLinks

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Links")
                .font(MovieBoxTypography.title)
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                if let imdbId = links.imdbId,
                   let url = URL(string: "https://www.imdb.com/name/\(imdbId)") {
                    linkButton(title: "IMDb", url: url)
                }
                if let homepage = profile.homepage, let url = URL(string: homepage) {
                    linkButton(title: "Website", url: url)
                }
                if let handle = links.instagramId?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty,
                   let url = URL(string: "https://instagram.com/\(handle)") {
                    linkButton(title: "Instagram", url: url)
                }
                if let handle = links.twitterId?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty,
                   let url = URL(string: "https://twitter.com/\(handle)") {
                    linkButton(title: "Twitter", url: url)
                }
            }
        }
    }

    private func linkButton(title: String, url: URL) -> some View {
        Link(destination: url) {
            Text(title)
                .font(MovieBoxTypography.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .adaptiveGlass(cornerRadius: 14, strength: .regular)
    }
}
