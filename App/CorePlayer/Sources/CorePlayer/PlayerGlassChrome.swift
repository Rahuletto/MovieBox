import SwiftUI

/// Shape passed to Liquid Glass on player HUD controls.
public enum PlayerGlassShape: Sendable {
    case circle
    case capsule
    case roundedRect(cornerRadius: CGFloat)
}

/// Material weight for player chrome over video.
public enum PlayerGlassStrength: Sendable {
    case regular
    case thick
}

/// Liquid Glass chrome for controls over video — uses semantic foreground so icons stay legible on bright scenes.
struct PlayerGlassChromeModifier: ViewModifier {
    let shape: PlayerGlassShape
    let strength: PlayerGlassStrength
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = interactive ? .regular.interactive() : .regular
            switch shape {
            case .circle:
                content.glassEffect(glass, in: .circle)
            case .capsule:
                content.glassEffect(glass, in: .capsule)
            case .roundedRect(let cornerRadius):
                content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            playerGlassFallback(content: content)
        }
    }

    private var fallbackMaterial: Material {
        switch strength {
        case .regular: .ultraThinMaterial
        case .thick: .thickMaterial
        }
    }

    @ViewBuilder
    private func playerGlassFallback(content: Content) -> some View {
        switch shape {
        case .circle:
            content
                .foregroundStyle(.primary)
                .background(fallbackMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.6))
        case .capsule:
            content
                .foregroundStyle(.primary)
                .background(fallbackMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.15), lineWidth: 0.6))
        case .roundedRect(let cornerRadius):
            let rect = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .foregroundStyle(.primary)
                .background(fallbackMaterial, in: rect)
                .overlay(rect.strokeBorder(.primary.opacity(0.15), lineWidth: 0.6))
        }
    }
}

public extension View {
    /// Native Liquid Glass with adaptive label/icon contrast (not fixed white).
    func playerGlassChrome(
        _ shape: PlayerGlassShape = .roundedRect(cornerRadius: 12),
        strength: PlayerGlassStrength = .thick,
        interactive: Bool = true
    ) -> some View {
        modifier(PlayerGlassChromeModifier(shape: shape, strength: strength, interactive: interactive))
    }

    /// SF Symbols on glass — hierarchical rendering adapts to light/dark glass foreground.
    func playerGlassSymbol() -> some View {
        symbolRenderingMode(.hierarchical)
    }

    func nativeGlassEffect(cornerRadius: CGFloat = 12) -> some View {
        playerGlassChrome(.roundedRect(cornerRadius: cornerRadius), interactive: true)
    }
}
