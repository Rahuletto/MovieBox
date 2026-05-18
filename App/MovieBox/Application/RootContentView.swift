import SwiftUI

struct RootContentView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack {
            RootTabStack()

            if case .movieDetail(let id) = router.selectedRoute {
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
