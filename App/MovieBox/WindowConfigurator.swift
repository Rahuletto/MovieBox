import AppKit
import SwiftUI

/// Inserts an invisible AppKit hook into the window so we can:
///   1. let the window content extend behind the titlebar (full-size content)
///   2. push the standard traffic-light buttons inward instead of letting
///      them hug the rounded corner of the window
///   3. set a softer, rounder window corner radius like Apple media apps
///
/// Apply once at the root of the scene:
///     RootView()
///         .background(WindowConfigurator(trafficLightInset: CGPoint(x: 20, y: 16)))
struct WindowConfigurator: NSViewRepresentable {
    let trafficLightInset: CGPoint

    func makeCoordinator() -> Coordinator {
        Coordinator(trafficLightInset: trafficLightInset)
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowTrackingView()
        view.onWindowAttached = { [weak coord = context.coordinator] window in
            coord?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator: NSObject {
        let trafficLightInset: CGPoint
        private weak var window: NSWindow?
        private var resizeObserver: NSObjectProtocol?
        private var becomeKeyObserver: NSObjectProtocol?

        init(trafficLightInset: CGPoint) {
            self.trafficLightInset = trafficLightInset
        }

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else {
                repositionButtons()
                return
            }
            self.window = window

            // Let our SwiftUI content sit underneath the titlebar so the chrome
            // looks continuous with the rest of the window.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden

            // Softer, rounder window corners — matches Apple's media apps
            // (Games, TV, Music) that use ~14pt radius instead of the system default ~10pt.
            window.backgroundColor = .windowBackgroundColor
            if let contentView = window.contentView?.superview {
                contentView.wantsLayer = true
                contentView.layer?.cornerRadius = 14
                contentView.layer?.cornerCurve = .continuous
                contentView.layer?.masksToBounds = true
            }

            repositionButtons()

            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
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
        }

        private func repositionButtons() {
            guard let window else { return }
            let order: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let spacing: CGFloat = 6
            var cursorX = trafficLightInset.x

            for type in order {
                guard
                    let button = window.standardWindowButton(type),
                    let titlebar = button.superview
                else { continue }

                var frame = button.frame
                frame.origin.x = cursorX
                // Center the buttons vertically with a gentle inset from the top
                frame.origin.y = titlebar.bounds.height - trafficLightInset.y - frame.height
                button.setFrameOrigin(frame.origin)
                cursorX += frame.width + spacing
            }
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
