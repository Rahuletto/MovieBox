import SwiftUI

enum SkipSeekDirection {
    case back
    case forward

    var tapDelta: Double {
        switch self {
        case .back: -15
        case .forward: 15
        }
    }

    var holdDelta: Double {
        switch self {
        case .back: -5
        case .forward: 5
        }
    }

    var icon15: String {
        switch self {
        case .back: "gobackward.15"
        case .forward: "goforward.15"
        }
    }

    var icon5: String {
        switch self {
        case .back: "gobackward.5"
        case .forward: "goforward.5"
        }
    }

    var iconFast: String {
        switch self {
        case .back: "backward.fill"
        case .forward: "forward.fill"
        }
    }
}

struct SkipSeekButton: View {
    @Bindable var state: PlayerState
    let direction: SkipSeekDirection
    let isCommandHeld: Bool
    @Binding var pulseTrigger: Int
    let onActivity: () -> Void

    @State private var isPressed = false
    @State private var didHoldRepeat = false
    @State private var repeatTask: Task<Void, Never>?
    @State private var renderedIcon: String
    @State private var iconMorphScale: CGFloat = 1
    @State private var morphTask: Task<Void, Never>?

    init(
        state: PlayerState,
        direction: SkipSeekDirection,
        isCommandHeld: Bool,
        pulseTrigger: Binding<Int>,
        onActivity: @escaping () -> Void
    ) {
        self.state = state
        self.direction = direction
        self.isCommandHeld = isCommandHeld
        self._pulseTrigger = pulseTrigger
        self.onActivity = onActivity
        _renderedIcon = State(initialValue: direction.icon15)
    }

    private var iconName: String {
        if isCommandHeld { return direction.iconFast }
        if isPressed { return direction.icon5 }
        return direction.icon15
    }

    var body: some View {
        Image(systemName: renderedIcon)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .scaleEffect(iconMorphScale)
            .frame(width: 52, height: 52)
            .nativeGlassEffect()
            .modifier(SkipButtonPulseModifier(trigger: pulseTrigger))
            .contentShape(Circle())
            .gesture(pressGesture)
            .onChange(of: iconName) { _, newIcon in
                morphIcon(to: newIcon)
            }
    }

    private func morphIcon(to newIcon: String) {
        guard newIcon != renderedIcon else { return }

        morphTask?.cancel()
        morphTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.09)) {
                iconMorphScale = 0.72
            }
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled else { return }

            renderedIcon = newIcon

            withAnimation(.easeOut(duration: 0.14)) {
                iconMorphScale = 1
            }
        }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                didHoldRepeat = false
                beginHold()
            }
            .onEnded { _ in
                let wasTap = isPressed && !didHoldRepeat
                endHold()
                isPressed = false
                if wasTap {
                    performTap()
                }
            }
    }

    private func performTap() {
        onActivity()
        if isCommandHeld {
            return
        }
        state.seek(by: direction.tapDelta)
        pulseTrigger += 1
    }

    private func beginHold() {
        onActivity()
        if isCommandHeld {
            didHoldRepeat = true
            switch direction {
            case .forward: state.startFastScan(forward: true)
            case .back: state.startFastScan(forward: false)
            }
            return
        }

        didHoldRepeat = true
        state.seek(by: direction.holdDelta)
        pulseTrigger += 1

        repeatTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            while !Task.isCancelled {
                await MainActor.run {
                    state.seek(by: direction.holdDelta)
                    pulseTrigger += 1
                    onActivity()
                }
                try? await Task.sleep(for: .milliseconds(280))
            }
        }
    }

    private func endHold() {
        repeatTask?.cancel()
        repeatTask = nil
        if isCommandHeld || state.isFastScanning {
            state.stopFastScan()
        }
    }
}
