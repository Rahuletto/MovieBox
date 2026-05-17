import SwiftUI

/// A reusable navigation header with a back button and optional title
/// - If title is provided: back button + title layout
/// - If title is nil: just the back button (left-aligned)
struct NavigationHeader: View {
    let title: String?
    let onBack: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            BackButton(action: onBack, title: title)
            Spacer()
        }
        .padding(.leading, 96)
        .padding(.trailing, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

#Preview {
    ZStack {
        LinearGradient(
            gradient: Gradient(colors: [.blue, .purple]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        
        VStack {
            NavigationHeader(title: "Animation", onBack: {})
            NavigationHeader(title: nil, onBack: {})
            Spacer()
        }
    }
}
