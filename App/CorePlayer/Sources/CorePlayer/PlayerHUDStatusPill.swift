import SwiftUI

/// Transient glass pill shown near the top of the player (fast scan speed, video fit mode, etc.).
public enum PlayerHUDStatusPillModel: Equatable, Sendable {
    case fastScan(icon: String, multiplier: Int)
    case playbackRate(rate: Double)
    case videoGravity(title: String, icon: String = "aspectratio")
    case qualityBadges(kinds: [PlayerQualityBadgeKind])
}

extension Animation {
    /// Liquid glass spring when the status pill appears or its content changes.
    static var playerHUDStatusPill: Animation {
        .spring(response: 0.34, dampingFraction: 0.72)
    }

    /// Slightly quicker, tighter spring when the pill dismisses.
    static var playerHUDStatusPillDismiss: Animation {
        .spring(response: 0.28, dampingFraction: 0.84)
    }
}

/// Top-center HUD pill host — drives its own enter/exit scale so transitions survive player clipping.
struct PlayerHUDStatusPillOverlay: View {
    let pill: PlayerHUDStatusPillModel?

    @State private var renderedPill: PlayerHUDStatusPillModel?
    @State private var isVisible = false
    @State private var dismissCleanupTask: Task<Void, Never>?

    private static let dismissCleanupDelay: Duration = .milliseconds(340)

    var body: some View {
        ZStack {
            if let renderedPill {
                PlayerHUDStatusPill(model: renderedPill)
                    .scaleEffect(isVisible ? 1 : 0.82, anchor: .center)
                    .opacity(isVisible ? 1 : 0)
                    .offset(y: isVisible ? 0 : 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .allowsHitTesting(false)
        .onAppear {
            sync(with: pill)
        }
        .onChange(of: pill) { _, newPill in
            sync(with: newPill)
        }
        .onDisappear {
            dismissCleanupTask?.cancel()
            dismissCleanupTask = nil
        }
    }

    private func sync(with newPill: PlayerHUDStatusPillModel?) {
        dismissCleanupTask?.cancel()
        dismissCleanupTask = nil

        if let newPill {
            if renderedPill == nil {
                renderedPill = newPill
                withAnimation(.playerHUDStatusPill) {
                    isVisible = true
                }
                return
            }

            if !isVisible {
                renderedPill = newPill
                withAnimation(.playerHUDStatusPill) {
                    isVisible = true
                }
                return
            }

            withAnimation(.playerHUDStatusPill) {
                renderedPill = newPill
            }
            return
        }

        guard renderedPill != nil, isVisible else {
            renderedPill = nil
            isVisible = false
            return
        }

        withAnimation(.playerHUDStatusPillDismiss) {
            isVisible = false
        }

        dismissCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: Self.dismissCleanupDelay)
            guard !Task.isCancelled, pill == nil else { return }
            renderedPill = nil
        }
    }
}

/// IINA / QuickTime–style status capsule at top center.
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
                    .contentTransition(.interpolate)
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
