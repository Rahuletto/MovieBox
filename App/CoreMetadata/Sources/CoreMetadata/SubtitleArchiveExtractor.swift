import Foundation

enum SubtitleArchiveExtractor {
    /// Extracts the first `.srt` from a subf2m ZIP payload (macOS `unzip`).
    static func extractSRT(from zipData: Data) throws -> Data {
        if zipData.starts(with: [0x50, 0x4B]) == false {
            if SubtitlePayloadValidator.looksLikeSRT(zipData) {
                return zipData
            }
            throw SubtitleError.invalidPayload
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moviebox_sub_zip_\(UUID().uuidString)", isDirectory: true)
        let zipURL = workDir.appendingPathComponent("archive.zip")
        let outDir = workDir.appendingPathComponent("out", isDirectory: true)

        defer { try? FileManager.default.removeItem(at: workDir) }

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try zipData.write(to: zipURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", outDir.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SubtitleError.invalidPayload
        }

        guard let enumerator = FileManager.default.enumerator(
            at: outDir,
            includingPropertiesForKeys: nil
        ) else {
            throw SubtitleError.invalidPayload
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "srt" else { continue }
            let data = try Data(contentsOf: fileURL)
            guard SubtitlePayloadValidator.looksLikeSRT(data) else { continue }
            return data
        }

        throw SubtitleError.invalidPayload
    }
}

public enum SubtitlePayloadValidator {
    public static func looksLikeSRT(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if data.starts(with: [0x50, 0x4B]) { return true }
        guard let text = String(data: data.prefix(4096), encoding: .utf8)
            ?? String(data: data.prefix(4096), encoding: .isoLatin1) else {
            return false
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
           text.contains("\"error\"") {
            return false
        }
        return text.contains("-->")
    }
}
