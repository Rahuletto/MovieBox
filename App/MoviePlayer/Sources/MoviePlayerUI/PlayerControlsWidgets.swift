import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


struct VolumeBoostSlider: View {
    @Binding var value: Double

    @State private var hoverVolume: Double?
    @State private var hoverX: CGFloat?
    @State private var isDragging = false

    private static let maxVolume = Double(PlayerState.maxVolume)
    private static let unityVolume = Double(PlayerState.unityVolume)
    private static let normalTrackFraction: CGFloat = 0.8
    private static let boostTrackFraction: CGFloat = 0.2

    private let trackHeight: CGFloat = 6
    private let boostFillColor = Color(red: 1, green: 0.55, blue: 0.18)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let unityMarkX = width * Self.normalTrackFraction
            let whiteWidth = whiteFillWidth(volume: value, trackWidth: width)
            let orangeWidth = orangeFillWidth(volume: value, trackWidth: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: trackHeight)

                Rectangle()
                    .fill(.white.opacity(0.32))
                    .frame(width: 1, height: trackHeight + 2)
                    .offset(x: unityMarkX - 0.5)

                Capsule()
                    .fill(.white)
                    .frame(width: max(0, whiteWidth), height: trackHeight)

                Capsule()
                    .fill(boostFillColor)
                    .frame(width: max(0, orangeWidth), height: trackHeight)
                    .offset(x: unityMarkX)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard !isDragging else { return }
                    let x = max(0, min(location.x, width))
                    hoverX = x
                    hoverVolume = volume(at: x, trackWidth: width)
                case .ended:
                    if !isDragging {
                        hoverVolume = nil
                        hoverX = nil
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let x = max(0, min(gesture.location.x, width))
                        value = volume(at: x, trackWidth: width)
                        hoverX = x
                        hoverVolume = value
                    }
                    .onEnded { _ in
                        isDragging = false
                        hoverVolume = nil
                        hoverX = nil
                    }
            )
        }
        .frame(height: 12)
        .overlay(alignment: .top) {
            if let labelVolume = volumeLabelValue {
                GeometryReader { labelGeometry in
                    let width = labelGeometry.size.width
                    let anchorX = hoverX ?? positionX(for: labelVolume, trackWidth: width)
                    volumePercentLabel(labelVolume)
                        .fixedSize()
                        .position(x: clampedLabelX(anchorX, trackWidth: width), y: -14)
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: volumeLabelValue != nil)
    }

    private var volumeLabelValue: Double? {
        if isDragging { return value }
        return hoverVolume
    }

    private func volumePercentLabel(_ volume: Double) -> some View {
        Text(Self.formatPercent(volume))
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.65), in: Capsule())
    }

    private func clampedLabelX(_ anchorX: CGFloat, trackWidth: CGFloat) -> CGFloat {
        let labelHalfWidth: CGFloat = 28
        return max(labelHalfWidth, min(anchorX, trackWidth - labelHalfWidth))
    }

    private func positionX(for volume: Double, trackWidth: CGFloat) -> CGFloat {
        let v = min(max(volume, 0), Self.maxVolume)
        if v <= Self.unityVolume {
            return CGFloat(v / Self.unityVolume) * trackWidth * Self.normalTrackFraction
        }
        let boost = (v - Self.unityVolume) / (Self.maxVolume - Self.unityVolume)
        return trackWidth * Self.normalTrackFraction + CGFloat(boost) * trackWidth * Self.boostTrackFraction
    }

    private static func formatPercent(_ volume: Double) -> String {
        "\(Int((volume * 100).rounded()))%"
    }

    private func whiteFillWidth(volume: Double, trackWidth: CGFloat) -> CGFloat {
        let clamped = min(max(volume, 0), Self.unityVolume)
        return CGFloat(clamped / Self.unityVolume) * trackWidth * Self.normalTrackFraction
    }

    private func orangeFillWidth(volume: Double, trackWidth: CGFloat) -> CGFloat {
        guard volume > Self.unityVolume else { return 0 }
        let boost = min(volume, Self.maxVolume) - Self.unityVolume
        let boostSpan = Self.maxVolume - Self.unityVolume
        return CGFloat(boost / boostSpan) * trackWidth * Self.boostTrackFraction
    }

    private func volume(at x: CGFloat, trackWidth: CGFloat) -> Double {
        guard trackWidth > 0 else { return 0 }
        let t = max(0, min(Double(x / trackWidth), 1))
        let normalEnd = Double(Self.normalTrackFraction)
        if t <= normalEnd {
            return (t / normalEnd) * Self.unityVolume
        }
        let boostT = (t - normalEnd) / Double(Self.boostTrackFraction)
        return Self.unityVolume + boostT * (Self.maxVolume - Self.unityVolume)
    }
}

// Custom Slider for Scrubber Progress
struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var onHoverTime: ((Double?, CGFloat?) -> Void)? = nil
    
    @State private var isHovering = false
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let percentage = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            
            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 6)
                
                // Active Filled Track
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, min(width * percentage, width)), height: 6)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if !hovering {
                    onHoverTime?(nil, nil)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let locationX = location.x
                    let relativeX = max(0, min(locationX, width))
                    let hoverVal = range.lowerBound + Double(relativeX / width) * (range.upperBound - range.lowerBound)
                    onHoverTime?(hoverVal, locationX)
                case .ended:
                    onHoverTime?(nil, nil)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let locationX = gesture.location.x
                        let relativeX = max(0, min(locationX, width))
                        let newValue = range.lowerBound + Double(relativeX / width) * (range.upperBound - range.lowerBound)
                        value = newValue
                    }
            )
        }
        .frame(height: 12)
    }
}

// Native macOS AirPlay Route Picker
struct AirPlayView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.isRoutePickerButtonBordered = false
        return routePicker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

// MARK: - Apple-Style Button Styles

struct AppleBlueButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        Color.accentColor.opacity(0.3),
                        lineWidth: 0.5
                    )
            )
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AppleSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        Color.secondary.opacity(0.2),
                        lineWidth: 0.5
                    )
            )
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
