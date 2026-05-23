import AppKit
import SwiftUI

/// Inserts an invisible AppKit hook into the window so we can:
///   1. let the window content extend behind the titlebar (full-size content)
///   2. push the standard traffic-light buttons inward instead of letting
///      them hug the rounded corner of the window
///   3. trigger the beautiful, premium large native macOS corner radius automatically
///      by attaching a transparent NSToolbar (concentric frame styling)
///   4. dynamically hide/show the toolbar during player presentation to completely remove the gray forehead bar!
///
/// Apply once at the root of the scene:
///     RootView()
///         .background(WindowConfigurator(trafficLightInset: CGPoint(x: 24, y: 20), isPlayerPresented: playerState.isPresented))
struct WindowConfigurator: NSViewRepresentable {
    let trafficLightInset: CGPoint
    let isPlayerPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(trafficLightInset: trafficLightInset, isPlayerPresented: isPlayerPresented)
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowTrackingView()
        view.onWindowAttached = { [weak coord = context.coordinator] window in
            coord?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(isPlayerPresented: isPlayerPresented)
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator: NSObject {
        private let windowCornerRadius: CGFloat = 14
        let trafficLightInset: CGPoint
        private(set) var isPlayerPresented: Bool
        private weak var window: NSWindow?
        private var resizeObserver: NSObjectProtocol?
        private var becomeKeyObserver: NSObjectProtocol?
        private var enterFSObserver: NSObjectProtocol?
        private var exitFSObserver: NSObjectProtocol?

        init(trafficLightInset: CGPoint, isPlayerPresented: Bool) {
            self.trafficLightInset = trafficLightInset
            self.isPlayerPresented = isPlayerPresented
        }

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
            if let enterFSObserver { NotificationCenter.default.removeObserver(enterFSObserver) }
            if let exitFSObserver { NotificationCenter.default.removeObserver(exitFSObserver) }
        }

        func update(isPlayerPresented: Bool) {
            guard self.isPlayerPresented != isPlayerPresented else { return }
            self.isPlayerPresented = isPlayerPresented
            applyToolbarState()
            applyWindowCornerMask()
            repositionButtons()
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else {
                repositionButtons()
                applyToolbarState()
                return
            }
            self.window = window

            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none

            if !isPlayerPresented && window.toolbar == nil {
                let dummyToolbar = NSToolbar(identifier: "MovieBox.WindowChromeToolbar")
                dummyToolbar.showsBaselineSeparator = false
                window.toolbar = dummyToolbar
            }

            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.mask = nil
                contentView.layer?.cornerRadius = 0
            }
            if let themeFrame = window.contentView?.superview {
                themeFrame.wantsLayer = true
                themeFrame.layer?.cornerRadius = 0
                themeFrame.layer?.masksToBounds = false
            }

            applyToolbarState()
            applyWindowCornerMask()
            repositionButtons()

            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.applyWindowCornerMask()
                self?.repositionButtons()
            }

            if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
            becomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.repositionButtons()
            }

            if let enterFSObserver { NotificationCenter.default.removeObserver(enterFSObserver) }
            enterFSObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.applyToolbarState()
                self?.applyWindowCornerMask()
            }

            if let exitFSObserver { NotificationCenter.default.removeObserver(exitFSObserver) }
            exitFSObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.applyToolbarState()
                self?.applyWindowCornerMask()
            }
        }

        private func applyToolbarState() {
            guard let window else { return }
            let isFullScreen = window.styleMask.contains(.fullScreen)

            if isPlayerPresented || isFullScreen {
                window.backgroundColor = .black
            } else {
                window.backgroundColor = .windowBackgroundColor
            }

            if isPlayerPresented || isFullScreen {
                // Completely strip the toolbar when player is active OR when in fullscreen mode.
                // This forces titlebarAppearsTransparent = true to render 100% clear.
                window.toolbar = nil
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            } else {
                // Restore dummy toolbar when in windowed mode and player is closed to preserve beautiful corner layouts.
                if window.toolbar == nil {
                    let dummyToolbar = NSToolbar(identifier: "MovieBox.WindowChromeToolbar")
                    dummyToolbar.showsBaselineSeparator = false
                    window.toolbar = dummyToolbar
                }
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
        }

        private func repositionButtons() {
            guard let window else { return }
            let order: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let spacing: CGFloat = 8
            var cursorX = trafficLightInset.x

            for type in order {
                guard
                    let button = window.standardWindowButton(type),
                    let titlebar = button.superview
                else { continue }
                
                button.isHidden = isPlayerPresented

                var frame = button.frame
                frame.origin.x = cursorX
                frame.origin.y = titlebar.bounds.height - trafficLightInset.y - frame.height
                button.setFrameOrigin(frame.origin)
                cursorX += frame.width + spacing
            }
        }

        private func applyWindowCornerMask() {
            guard let window else { return }
            let isFullScreen = window.styleMask.contains(.fullScreen)
            guard let contentView = window.contentView else { return }

            contentView.wantsLayer = true
            if isFullScreen {
                contentView.layer?.cornerRadius = 0
                contentView.layer?.masksToBounds = false
                contentView.layer?.backgroundColor = NSColor.black.cgColor
                return
            }

            contentView.layer?.backgroundColor = nil

            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.cornerRadius = windowCornerRadius
            contentView.layer?.masksToBounds = true
        }
    }
}

private final class WindowTrackingView: NSView {
    var onWindowAttached: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Defer so the system has a chance to lay out the standard buttons first.
        DispatchQueue.main.async { [weak self] in
            self?.onWindowAttached?(window)
        }
    }
}
