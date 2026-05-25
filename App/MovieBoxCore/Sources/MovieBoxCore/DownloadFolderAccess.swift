import Foundation

/// Retains security-scoped access for a user-picked download folder (App Sandbox).
@MainActor
public enum DownloadFolderAccess {
    private static let bookmarkKey = "com.moviebox.downloadFolderBookmark"
    private static var scopedURL: URL?
    private static var isAccessing = false

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

    /// Starts security-scoped access when the active download path matches a stored bookmark.
    public static func activate(for directory: URL) {
        deactivate()
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }

        let target = directory.standardizedFileURL
        let granted = resolved.standardizedFileURL
        guard target.path == granted.path || target.path.hasPrefix(granted.path + "/") else { return }

        if stale {
            storeUserSelectedFolder(granted)
        }

        if granted.startAccessingSecurityScopedResource() {
            scopedURL = granted
            isAccessing = true
        }
    }

    public static func deactivate() {
        if isAccessing, let url = scopedURL {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURL = nil
        isAccessing = false
    }
}
