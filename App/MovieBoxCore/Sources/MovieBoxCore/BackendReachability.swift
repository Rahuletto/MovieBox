import CoreMetadata
import Foundation

public enum BackendReachability {
  /// Quick GET `/health` — returns false on TLS/timeout (Worker down or unreachable).
  public static func isHealthy(baseURL: URL, appToken: String) async -> Bool {
    let healthURL = baseURL.appending(path: "health")
    var request = URLRequest(url: healthURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 8
    request.setValue(appToken, forHTTPHeaderField: "X-MovieBox-Token")
    do {
      let (_, response) = try await BackendURLSession.urlSession.data(for: request)
      guard let http = response as? HTTPURLResponse else { return false }
      return (200..<300).contains(http.statusCode)
    } catch {
      await MainActor.run {
        LogStore.shared.log(.warn, category: "network", "Backend health check failed: \(error.localizedDescription)")
      }
      return false
    }
  }
}
