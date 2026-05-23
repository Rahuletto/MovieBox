import SwiftUI

/// Transient glass pill shown near the top of the player (fast scan speed, video fit mode, etc.).
public enum PlayerHUDStatusPillModel: Equatable, Sendable {
    case fastScan(icon: String, multiplier: Int)
    case playbackRate(rate: Double)
    case videoGravity(title: String, icon: String = "aspectratio")
    case qualityBadges(kinds: [PlayerQualityBadgeKind])
}

extension Animation {
    /// Scale warp for the top-center status pill (fast scan, fit mode, etc.).
    static var playerHUDStatusPill: Animation {
        .spring(response: 0.34, dampingFraction: 0.74)
    }
}

extension AnyTransition {
    static var playerHUDStatusPillWarp: AnyTransition {
        .scale(scale: 0.52, anchor: .center)
    }
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
                Text("\(multiplier)x")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            case .playbackRate(let rate):
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text("\(rate, specifier: "%g")x")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            case .videoGravity(let title, let icon):
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            case .qualityBadges(let kinds):
                HStack(spacing: 10) {
                    ForEach(kinds, id: \.self) { kind in
                        PlayerQualityBadgeImage(kind: kind)
                            .accessibilityLabel(kind.accessibilityLabel)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .nativeGlassEffect()
        .animation(.playerHUDStatusPill, value: model)
    }
}
