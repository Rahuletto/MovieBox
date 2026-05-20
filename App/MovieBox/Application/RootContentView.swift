import SwiftUI

struct RootContentView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack {
            RootTabStack()

            if case .personDetail(let id) = router.selectedRoute {
                PersonDetailView(
                    personId: id,
                    onBack: { router.backFromPerson() }
                )
                .id("person-detail-\(id)")
                .transition(.opacity)
                .zIndex(2)
            } else if case .movieDetail(let id) = router.selectedRoute {
                MovieDetailView(
                    movieId: id,
                    kind: router.detailKind,
                    onBack: { router.backFromDetail() }
                )
                .id("movie-detail-\(id)")
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }
}
