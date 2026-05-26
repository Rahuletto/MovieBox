import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


// Custom Slider for Volume & Scrubber Progress
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
