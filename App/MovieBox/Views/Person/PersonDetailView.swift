import CoreMetadata
import CoreStorage
import DesignSystem
import MovieBoxCore
import SwiftData
import SwiftUI

struct PersonDetailView: View {
    @Query private var settings: [AppSettings]
    @State private var detail: PersonDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let personId: Int
    private let onBack: () -> Void

    init(personId: Int, onBack: @escaping () -> Void) {
        self.personId = personId
        self.onBack = onBack
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PersonProfileBackdrop(profilePath: detail?.profile.profilePath)
                .ignoresSafeArea()

            ScrollView {
                PersonDetailContentView(
                    detail: detail,
                    isLoading: isLoading
                )
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)

            if let errorMessage {
                DetailErrorOverlay(message: errorMessage, onRetry: { Task { await load() } })
            }

            NavigationHeader(
                title: detail?.profile.name,
                onBack: onBack
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: personId) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let mode = settings.first?.metadataMode else {
            errorMessage = "Metadata is not configured."
            return
        }

        do {
            let client = MetadataClient(mode: mode)
            detail = try await client.personDetail(id: personId)
        } catch {
            #if DEBUG
            print("[PersonDetail] load failed id=\(personId): \(error)")
            #endif
            LogStore.shared.log(.error, category: "metadata", "Person detail failed id=\(personId) — \(error.localizedDescription)")
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't load this person. Try again."
        }
    }
}
