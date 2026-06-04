import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .frame(width: 32, height: 32)
            .background(.white.opacity(0.08))
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CenterHUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

enum GlassStrength {
    case ultraThin
    case thin
    case regular
    case thick
    case ultraThick
    
    var material: Material {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        case .ultraThick: return .ultraThickMaterial
        }
    }
}

struct NativeVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct AdaptiveGlass: ViewModifier {
    private let cornerRadius: CGFloat
    private let strength: GlassStrength

    public init(cornerRadius: CGFloat = 18, strength: GlassStrength = .thick) {
        self.cornerRadius = cornerRadius
        self.strength = strength
    }

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(
                    NativeVisualEffectView(material: .hudWindow, blendingMode: .withinWindow, state: .active)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        }
    }
}

extension View {
    func adaptiveGlass(cornerRadius: CGFloat = 18, strength: GlassStrength = .thick) -> some View {
        modifier(AdaptiveGlass(cornerRadius: cornerRadius, strength: strength))
    }
}

struct HUDPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .frame(width: 44, height: 44)
            .background(.white)
            .clipShape(Circle())
            .shadow(color: .white.opacity(0.2), radius: 6)
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct VolumeSlider: View {
    let volume: Float
    let onValueChange: (Float) -> Void

    var body: some View {
        Slider(value: Binding(
            get: { Double(volume) },
            set: { onValueChange(Float($0)) }
        ), in: 0...1) {
            Text("Volume")
        }
        .tint(.white)
        .controlSize(.mini)
    }
}

struct PlayerVolumeIcon: View {
    let isMuted: Bool
    let volume: Float
    let iconFont: CGFloat
    let frameSize: CGFloat

    private static let boostWaveColor = Color(red: 1, green: 0.55, blue: 0.18)

    private var isSilent: Bool {
        isMuted || volume <= 0.001
    }

    private var boostBlend: Double {
        guard !isSilent, volume > PlayerState.unityVolume else { return 0 }
        let span = PlayerState.maxVolume - PlayerState.unityVolume
        guard span > 0 else { return 0 }
        return Double(min(max((volume - PlayerState.unityVolume) / span, 0), 1))
    }

    private var waveColor: Color {
        let blend = boostBlend
        return Color(
            red: 1,
            green: 1 - (1 - 0.55) * blend,
            blue: 1 - (1 - 0.18) * blend
        )
    }

    private var clampedVolume: Double {
        Double(min(max(volume, 0), PlayerState.unityVolume))
    }

    private var symbolName: String {
        isSilent ? "speaker.slash.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        Image(systemName: symbolName, variableValue: isSilent ? 0 : clampedVolume)
            .font(.system(size: iconFont, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.primary, waveColor)
            .frame(width: frameSize, height: frameSize)
            .contentShape(Rectangle())
            .contentTransition(.symbolEffect(.replace))
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: symbolName)
            .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.88), value: clampedVolume)
            .animation(.easeInOut(duration: 0.28), value: boostBlend)
    }
}
