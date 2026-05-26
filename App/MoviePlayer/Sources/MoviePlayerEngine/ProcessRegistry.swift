import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Thread-safe registry that keeps track of all running subprocesses (like ffmpeg/ffprobe)
/// and terminates them if the host application terminates or crashes.
public final class ProcessRegistry: @unchecked Sendable {
    public static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var processes = Set<Process>()

    private init() {
        #if canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.terminateAll()
        }
        #endif
    }

    public func register(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        processes.insert(process)
    }

    public func unregister(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        processes.remove(process)
    }

    public func terminateAll() {
        lock.lock()
        let active = processes
        processes.removeAll()
        lock.unlock()

        for process in active {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

/// A wrapper around Process that handles automatic cleanup upon object deinit.
public final class ProcessWrapper: @unchecked Sendable {
    public let process: Process

    public init(_ process: Process) {
        self.process = process
        ProcessRegistry.shared.register(process)
    }

    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
        ProcessRegistry.shared.unregister(process)
    }

    deinit {
        terminate()
    }
}
