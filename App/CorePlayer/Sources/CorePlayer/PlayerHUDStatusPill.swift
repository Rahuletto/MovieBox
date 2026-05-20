import SwiftUI

/// Transient glass pill shown near the top of the player (fast scan speed, video fit mode, etc.).
public enum PlayerHUDStatusPillModel: Equatable, Sendable {
    case fastScan(icon: String, multiplier: Int)
    case videoGravity(title: String, icon: String = "aspectratio")
}

/// IINA / QuickTime–style status capsule: scale “warp” for show/hide and content changes (no soft fade).
public struct PlayerHUDStatusPill: View {
    public let model: PlayerHUDStatusPillModel

    public init(model: PlayerHUDStatusPillModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 8) {
            switch model {
            case .fastScan(let icon, let multiplier):
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text("\(multiplier)×")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            case .videoGravity(let title, let icon):
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.interpolate)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .nativeGlassEffect()
        .animation(.spring(response: 0.32, dampingFraction: 0.76), value: model)
    }
}

extension AnyTransition {
    /// Pop-in / warp without relying on opacity (reads sharper on video).
    static var hudStatusPillWarp: AnyTransition {
        .scale(scale: 0.52, anchor: .center)
    }
}
