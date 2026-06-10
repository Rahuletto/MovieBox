import Foundation
import SQLite3

/// Credentials and proxy settings kept outside SwiftData so a store reset cannot wipe them.
public struct AppSettingsBackup: Codable, Sendable, Equatable {
    public var proxyBaseURL: String
    public var useLocalBackend: Bool
    public var appToken: String
    public var tmdbBearerToken: String
    public var omdbAPIKey: String

    public init(
        proxyBaseURL: String = "",
        useLocalBackend: Bool = false,
        appToken: String = "",
        tmdbBearerToken: String = "",
        omdbAPIKey: String = ""
    ) {
        self.proxyBaseURL = proxyBaseURL
        self.useLocalBackend = useLocalBackend
        self.appToken = appToken
        self.tmdbBearerToken = tmdbBearerToken
        self.omdbAPIKey = omdbAPIKey
    }

    public var hasAnyCredential: Bool {
        !appToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tmdbBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum AppSettingsBackupStore {
    private static let userDefaultsKey = "MovieBox.AppSettingsBackup.v1"

    public static func capture(from settings: AppSettings) -> AppSettingsBackup {
        AppSettingsBackup(
            proxyBaseURL: settings.proxyBaseURL,
            useLocalBackend: settings.useLocalBackend,
            appToken: settings.appToken,
            tmdbBearerToken: settings.tmdbBearerToken,
            omdbAPIKey: settings.omdbAPIKey
        )
    }

    public static func save(from settings: AppSettings) {
        save(backup: capture(from: settings))
    }

    public static func save(backup: AppSettingsBackup) {
        guard backup.hasAnyCredential || !backup.proxyBaseURL.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(backup) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    public static func load() -> AppSettingsBackup? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(AppSettingsBackup.self, from: data)
    }

    /// Restores missing credential fields from the last backup (never overwrites non-empty values).
    @discardableResult
    public static func restoreMissingFields(on settings: AppSettings) -> Bool {
        guard let backup = load() else { return false }
        var changed = false

        if settings.proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !backup.proxyBaseURL.isEmpty {
            settings.proxyBaseURL = backup.proxyBaseURL
            changed = true
        }
        if settings.appToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !backup.appToken.isEmpty {
            settings.appToken = backup.appToken
            changed = true
        }
        if settings.tmdbBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !backup.tmdbBearerToken.isEmpty {
            settings.tmdbBearerToken = backup.tmdbBearerToken
            changed = true
        }
        if settings.omdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !backup.omdbAPIKey.isEmpty {
            settings.omdbAPIKey = backup.omdbAPIKey
            changed = true
        }
        if !settings.useLocalBackend, backup.useLocalBackend {
            settings.useLocalBackend = backup.useLocalBackend
            changed = true
        }
        return changed
    }

    /// Reads credentials from an on-disk SwiftData store before it is deleted (best-effort).
    public static func captureFromSQLiteStore(at storeURL: URL) -> AppSettingsBackup? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT ZPROXYBASEURL, ZAPPTOKEN, ZTMDBBEARERTOKEN, ZOMDBAPIKEY
            FROM ZAPPSETTINGS LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        func text(_ column: Int32) -> String {
            guard let cString = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: cString)
        }

        return AppSettingsBackup(
            proxyBaseURL: text(0),
            useLocalBackend: false,
            appToken: text(1),
            tmdbBearerToken: text(2),
            omdbAPIKey: text(3)
        )
    }
}
