import CoreStreaming
import Foundation

/// Retains security-scoped access for user-picked folders outside entitlement-backed library paths.
@MainActor
public enum DownloadFolderAccess {
    private static let bookmarkKey = "com.moviebox.downloadFolderBookmark"
    private static var scopedURL: URL?
    private static var isAccessing = false

    public static var hasStoredBookmark: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    public static func storeUserSelectedFolder(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            scopedURL = url.standardizedFileURL
        } catch {
            NSLog("MovieBox DownloadFolderAccess: failed to store bookmark — %@", error.localizedDescription)
        }
    }

    public static func resolvedBookmarkURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale {
            storeUserSelectedFolder(resolved)
        }
        return resolved.standardizedFileURL
    }

    /// Begins access for entitlement-backed library paths or a stored security-scoped bookmark.
    @discardableResult
    public static func beginAccess(to directory: URL) -> Bool {
        deactivate()
        let target = directory.standardizedFileURL

        if DownloadStorage.isEntitlementBackedPath(target) {
            return true
        }

        if let granted = resolvedBookmarkURL(), directoriesOverlap(target, granted) {
            if granted.startAccessingSecurityScopedResource() {
                scopedURL = granted
                isAccessing = true
                return true
            }
        }

        return !DownloadStorage.isRunningInAppSandbox
    }

    public static func deactivate() {
        if isAccessing, let url = scopedURL {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURL = nil
        isAccessing = false
    }

    private static func directoriesOverlap(_ a: URL, _ b: URL) -> Bool {
        DownloadStorage.isContained(a, in: b) || DownloadStorage.isContained(b, in: a)
    }
}
