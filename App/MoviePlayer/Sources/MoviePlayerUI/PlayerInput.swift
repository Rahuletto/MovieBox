import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI



extension Notification.Name {
    static let playerReclaimKeyboardFocus = Notification.Name("playerReclaimKeyboardFocus")
}

/// Invisible first-responder layer — SwiftUI `onKeyPress` does not receive keys when AVPlayer uses an `NSView` layer.
struct PlayerKeyboardCaptureView: NSViewRepresentable {
    var state: PlayerState
    var onActivity: () -> Void
    var onSkipBack: () -> Void
    var onSkipForward: () -> Void
    var onCommandHeld: (Bool) -> Void
    var onShiftHeld: (Bool) -> Void

    func makeNSView(context: Context) -> PlayerKeyboardNSView {
        let view = PlayerKeyboardNSView()
        view.state = state
        view.onActivity = onActivity
        view.onSkipBack = onSkipBack
        view.onSkipForward = onSkipForward
        view.onCommandHeld = onCommandHeld
        view.onShiftHeld = onShiftHeld
        return view
    }

    func updateNSView(_ nsView: PlayerKeyboardNSView, context: Context) {
        nsView.state = state
        nsView.onActivity = onActivity
        nsView.onSkipBack = onSkipBack
        nsView.onSkipForward = onSkipForward
        nsView.onCommandHeld = onCommandHeld
        nsView.onShiftHeld = onShiftHeld
        if state.isPresented {
            nsView.claimKeyboardFocus()
            nsView.syncModifierFlags(NSEvent.modifierFlags)
        }
    }

    static func dismantleNSView(_ nsView: PlayerKeyboardNSView, coordinator: ()) {
        nsView.teardown()
    }
}

final class PlayerKeyboardNSView: NSView {
    weak var state: PlayerState?
    var onActivity: (() -> Void)?
    var onSkipBack: (() -> Void)?
    var onSkipForward: (() -> Void)?
    var onCommandHeld: ((Bool) -> Void)?
    var onShiftHeld: ((Bool) -> Void)?
    private var focusObserver: NSObjectProtocol?
    private var isCommandKeyHeld = false
    private var isShiftKeyHeld = false

    override var acceptsFirstResponder: Bool { true }

    func teardown() {
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusObserver == nil {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .playerReclaimKeyboardFocus,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.claimKeyboardFocus()
            }
        }
        claimKeyboardFocus()
    }

    func claimKeyboardFocus() {
        guard state?.isPresented == true else { return }
        window?.makeFirstResponder(self)
    }

    func syncModifierFlags(_ modifierFlags: NSEvent.ModifierFlags) {
        let commandDown = modifierFlags.contains(.command)
        if commandDown != isCommandKeyHeld {
            isCommandKeyHeld = commandDown
            DispatchQueue.main.async { [weak self] in
                self?.onCommandHeld?(commandDown)
            }
        }

        let shiftDown = modifierFlags.contains(.shift)
        if shiftDown != isShiftKeyHeld {
            isShiftKeyHeld = shiftDown
            DispatchQueue.main.async { [weak self] in
                self?.onShiftHeld?(shiftDown)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func flagsChanged(with event: NSEvent) {
        let commandDown = event.modifierFlags.contains(.command)
        if commandDown != isCommandKeyHeld {
            isCommandKeyHeld = commandDown
            onCommandHeld?(commandDown)
        }
        let shiftDown = event.modifierFlags.contains(.shift)
        if shiftDown != isShiftKeyHeld {
            isShiftKeyHeld = shiftDown
            onShiftHeld?(shiftDown)
        }
        if !commandDown {
            state?.stopFastScan()
        }
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let state else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) {
            super.keyDown(with: event)
            return
        }

        if handleKeyDown(event, state: state) {
            onActivity?()
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 {
            if event.modifierFlags.contains(.command) || state?.isFastScanning == true {
                state?.stopFastScan()
            }
        }
        super.keyUp(with: event)
    }

    private func handleKeyDown(_ event: NSEvent, state: PlayerState) -> Bool {
        let isCommand = event.modifierFlags.contains(.command)
        let isShift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 49: // space
            guard !isCommand, !isShift else { return false }
            state.togglePlayback()
            return true
        case 123: // left
            if isCommand {
                state.startFastScan(forward: false)
                onSkipBack?()
                return true
            }
            if isShift {
                state.seek(by: -5)
                onSkipBack?()
                return true
            }
            state.seek(by: -15)
            onSkipBack?()
            return true
        case 124: // right
            if isCommand {
                state.startFastScan(forward: true)
                onSkipForward?()
                return true
            }
            if isShift {
                state.seek(by: 5)
                onSkipForward?()
                return true
            }
            state.seek(by: 15)
            onSkipForward?()
            return true
        case 126: // up
            guard !isCommand, !isShift else { return false }
            state.setVolume(min(1.0, state.volume + 0.1))
            return true
        case 125: // down
            guard !isCommand, !isShift else { return false }
            state.setVolume(max(0.0, state.volume - 0.1))
            return true
        case 53: // escape
            state.dismiss()
            return true
        default:
            break
        }

        guard !isCommand, !isShift else { return false }

        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else {
            return false
        }

        switch key {
        case "m":
            state.toggleMute()
            return true
        case "f":
            state.toggleFullScreen()
            return true
        case "s", "c":
            state.toggleSubtitle()
            return true
        case "p":
            state.togglePictureInPicture()
            return true
        case "a":
            state.cycleVideoGravity()
            return true
        default:
            return false
        }
    }
}

struct SkipButtonPulseModifier: ViewModifier {
    let trigger: Int
    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: trigger) { _, _ in
                scale = 1.14
                withAnimation(.spring(response: 0.1, dampingFraction: 0.52)) {
                    scale = 1.0
                }
            }
    }
}

struct MouseTrackingView: NSViewRepresentable {
    let onMove: () -> Void

    func makeNSView(context: Context) -> MouseTrackingNSView {
        let view = MouseTrackingNSView()
        view.onMove = onMove
        let tracker = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: view,
            userInfo: nil
        )
        view.addTrackingArea(tracker)
        return view
    }

    func updateNSView(_ nsView: MouseTrackingNSView, context: Context) {
        nsView.onMove = onMove
    }
}

class MouseTrackingNSView: NSView {
    var onMove: (() -> Void)?

    override func mouseMoved(with event: NSEvent) {
        onMove?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Fullscreen cursor

private enum PlaybackCursorPolicy {
    static func sync(showsControls: Bool, isActive: Bool, window: NSWindow?) {
        guard isActive, isFullScreen(window) else {
            restore()
            return
        }
        if showsControls {
            NSCursor.unhide()
        } else {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    static func restore() {
        NSCursor.unhide()
    }

    private static func isFullScreen(_ window: NSWindow?) -> Bool {
        if window?.styleMask.contains(.fullScreen) == true { return true }
        if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { return true }
        return NSApp.mainWindow?.styleMask.contains(.fullScreen) == true
    }
}

struct PlaybackCursorView: NSViewRepresentable {
    let showsControls: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> PlaybackCursorNSView {
        PlaybackCursorNSView()
    }

    func updateNSView(_ nsView: PlaybackCursorNSView, context: Context) {
        nsView.showsControls = showsControls
        nsView.isActive = isActive
        nsView.syncCursor()
    }

    static func dismantleNSView(_ nsView: PlaybackCursorNSView, coordinator: ()) {
        nsView.teardown()
        PlaybackCursorPolicy.restore()
    }
}

final class PlaybackCursorNSView: NSView {
    var showsControls = true
    var isActive = false
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowObservers()
        syncCursor()
    }

    func syncCursor() {
        PlaybackCursorPolicy.sync(
            showsControls: showsControls,
            isActive: isActive,
            window: window
        )
    }

    func teardown() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func installWindowObservers() {
        teardown()
        guard let window else { return }

        let names: [Notification.Name] = [
            NSWindow.willEnterFullScreenNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.syncCursor()
                }
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
