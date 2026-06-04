import DesignSystem
import SwiftUI

struct LibraryView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            AmbientPageGlow(color: MovieBoxColors.libraryGlow)

            MyListView()
                .padding(.top, AppLayout.topBarReservedHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
