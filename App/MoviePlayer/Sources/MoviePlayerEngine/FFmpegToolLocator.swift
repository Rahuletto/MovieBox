import Foundation

public enum FFmpegToolLocator {
    public static func url(for name: String) -> URL? {
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: name),
           FileManager.default.isExecutableFile(atPath: auxiliary.path) {
            return auxiliary
        }
        if let resource = Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: resource.path) {
            return resource
        }
        let macOSBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/\(name)")
        if FileManager.default.isExecutableFile(atPath: macOSBinary.path) {
            return macOSBinary
        }
        return nil
    }

    public static var isAvailable: Bool {
        url(for: "ffmpeg") != nil && url(for: "ffprobe") != nil
    }
}
