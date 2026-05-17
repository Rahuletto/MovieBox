import Foundation

public enum TaskTimeoutError: LocalizedError {
    case timedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "Timed out after \(Int(seconds)) seconds."
        }
    }
}

public enum TaskTimeout {
    public static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TaskTimeoutError.timedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw TaskTimeoutError.timedOut(seconds: seconds)
            }
            return value
        }
    }
}
