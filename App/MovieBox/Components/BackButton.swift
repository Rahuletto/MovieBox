import SwiftUI
import DesignSystem

struct BackButton: View {
    let action: () -> Void
    let title: String?
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .adaptiveGlass(cornerRadius: 32)
//            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            
            if let title {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        BackButton(action: {}, title: "Adventure")
        BackButton(action: {}, title: nil)
    }
    .padding()
}
