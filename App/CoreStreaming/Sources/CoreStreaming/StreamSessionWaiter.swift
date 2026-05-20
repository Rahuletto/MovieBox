import Foundation

extension StreamSession {
    /// Polls until the session reaches a terminal state or `timeout` elapses (then cancels).
    @MainActor
    public func waitUntilSettled(timeout: TimeInterval = 240) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, Date() < deadline {
            switch state {
            case .ready, .failed, .cancelled:
                return
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        if case .ready = state { return }
        if case .failed = state { return }
        if case .cancelled = state { return }

        await failWithTimeout()
    }
}
