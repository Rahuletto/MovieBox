import CoreMetadata
import CoreStorage
import Foundation

public enum MetadataSettings {
    public static func mode(from settings: [AppSettings]) -> MetadataEndpointMode? {
        settings.first?.metadataMode
    }

    public static func client(from settings: [AppSettings]) -> MetadataClient? {
        guard let mode = mode(from: settings) else { return nil }
        return MetadataClient(mode: mode)
    }

    public static func requireMode(from settings: [AppSettings]) -> MetadataEndpointMode? {
        mode(from: settings)
    }
}
