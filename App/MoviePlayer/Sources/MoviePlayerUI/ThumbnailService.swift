import AVFoundation
import CoreGraphics
import Foundation

/// Generates and caches scrubber preview frames from an `AVAsset`.
actor ThumbnailService {
    private let generator: AVAssetImageGenerator
    private var cache: [Int: CGImage] = [:]
    private var cacheOrder: [Int] = []
    private var latestRequestID: UInt64 = 0

    private static let cacheLimit = 32
    private static let bucketSeconds: Double = 1

    init(asset: AVAsset) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        generator = gen
    }

    /// Returns a cached or newly generated thumbnail for the given playback time.
    /// `requestID` is echoed back so callers can ignore stale async results.
    func thumbnail(at seconds: Double, requestID: UInt64) async -> (requestID: UInt64, image: CGImage?) {
        let clamped = max(0, seconds)
        let bucket = Int(clamped / Self.bucketSeconds)

        if let cached = cache[bucket] {
            touchCache(bucket)
            return (requestID, cached)
        }

        latestRequestID = requestID

        do {
            let time = CMTime(seconds: Double(bucket) * Self.bucketSeconds, preferredTimescale: 600)
            let image = try await generateImage(at: time)

            guard latestRequestID == requestID else {
                return (requestID, nil)
            }

            store(bucket: bucket, image: image)
            return (requestID, image)
        } catch {
            return (requestID, nil)
        }
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        generator.cancelAllCGImageGeneration()
    }

    private func generateImage(at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()

            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                guard !resumed.take() else { return }

                if result == .succeeded, let image {
                    continuation.resume(returning: image)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ThumbnailService",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "No preview frame at this time"]
                        )
                    )
                }
            }
        }
    }

    private func store(bucket: Int, image: CGImage) {
        cache[bucket] = image
        touchCache(bucket)
        while cacheOrder.count > Self.cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func touchCache(_ bucket: Int) {
        cacheOrder.removeAll { $0 == bucket }
        cacheOrder.append(bucket)
    }
}

/// Thread-safe one-shot flag for continuation safety.
private final class LockedFlag: @unchecked Sendable {
    private var consumed = false
    private let lock = NSLock()

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if consumed { return true }
        consumed = true
        return false
    }
}
