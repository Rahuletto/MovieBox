import CoreStorage
import Foundation
import Observation

@MainActor
@Observable
public final class AppErrorCenter {
    public struct PresentedError: Identifiable, Equatable {
        public let id = UUID()
        public let title: String
        public let message: String
        public let recovery: String?
        public let context: String
    }

    public private(set) var current: PresentedError?

    public init() {}

    public func present(_ error: Error, context: String) {
        let boxed = error.asMovieBoxError
        current = PresentedError(
            title: context,
            message: boxed.errorDescription ?? error.localizedDescription,
            recovery: boxed.recoverySuggestion,
            context: context
        )
        LogStore.shared.logError(error, context: context, category: "error")
    }

    public func dismiss() {
        current = nil
    }
}
