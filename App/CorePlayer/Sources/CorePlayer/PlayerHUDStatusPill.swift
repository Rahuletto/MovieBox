import SwiftUI

/// Transient glass pill shown near the top of the player (fast scan speed, video fit mode, etc.).
public enum PlayerHUDStatusPillModel: Equatable, Sendable {
    case fastScan(icon: String, multiplier: Int)
    case playbackRate(rate: Double)
    case videoGravity(title: String, icon: String = "aspectratio")
    case qualityBadges(kinds: [PlayerQualityBadgeKind])
}

extension Animation {
    /// Fade for the top-center status pill (fit mode, quality badges, fast scan).
    static var playerHUDStatusPill: Animation {
        .easeInOut(duration: 0.22)
    }
}

extension AnyTransition {
    static var playerHUDStatusPillWarp: AnyTransition {
        .opacity
    }
}

/// IINA / QuickTime–style status capsule at top center — fades in/out on show and content change.
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
                    .font(.system(size: 14, weight: .bold))
                    .playerGlassSymbol()
                    .contentTransition(.symbolEffect(.replace))
                Text("\(multiplier)x")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            case .playbackRate(let rate):
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .bold))
                    .playerGlassSymbol()
                    .contentTransition(.symbolEffect(.replace))
                Text("\(rate, specifier: "%g")x")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            case .videoGravity(let title, let icon):
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .playerGlassSymbol()
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            case .qualityBadges(let kinds):
                HStack(spacing: 12) {
                    ForEach(kinds, id: \.self) { kind in
                        PlayerQualityBadgeImage(kind: kind)
                            .accessibilityLabel(kind.accessibilityLabel)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .playerGlassChrome(.capsule)
    }
}
