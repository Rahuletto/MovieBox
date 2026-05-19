import Foundation

/// Fetches YouTube video duration (seconds) via public Piped instances for trailer sorting.
enum YouTubeDurationResolver {
    private static let pipedBases = [
        "https://pipedapi.kavin.rocks",
        "https://pipedapi.adminforge.de",
    ]
    private static var cache: [String: Int] = [:]
    private static let cacheLock = NSLock()

    static func durations(for keys: [String]) async -> [String: Int] {
        var result: [String: Int] = [:]
        await withTaskGroup(of: (String, Int?).self) { group in
            for key in keys {
                group.addTask { await (key, duration(for: key)) }
            }
            for await (key, value) in group {
                if let value { result[key] = value }
            }
        }
        return result
    }

    static func duration(for key: String) async -> Int? {
        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        struct PipedPayload: Decodable {
            let duration: Int?
        }

        for base in pipedBases {
            guard let url = URL(string: "\(base)/streams/\(key)") else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continue
                }
                let payload = try JSONDecoder().decode(PipedPayload.self, from: data)
                if let duration = payload.duration, duration > 0 {
                    cacheLock.lock()
                    cache[key] = duration
                    cacheLock.unlock()
                    return duration
                }
            } catch {
                continue
            }
        }
        return nil
    }
}
