import MovieBoxCore
import SwiftUI

struct AppErrorBanner: View {
    @Environment(AppErrorCenter.self) private var errorCenter

    var body: some View {
        if let error = errorCenter.current {
            VStack {
                RetryCard(message: error.message) {
                    errorCenter.dismiss()
                }
                .frame(maxWidth: 420)
                .padding(.top, 72)
                Spacer()
            }
            .transition(.opacity)
        }
    }
}
