import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

public struct StreamQualityDiagnostics: Sendable, Equatable {
    public var hdrType: PlayerHDRType?
    public var audioFormat: PlayerAudioFormat?
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var videoRange: String?
    public var codecs: String?
    public var resolution: String?
    public var peakBitrate: String?
    public var atmosRendition: String?
    public var source: String

    public init(
        hdrType: PlayerHDRType? = nil,
        audioFormat: PlayerAudioFormat? = nil,
        colorPrimaries: String? = nil,
        colorTransfer: String? = nil,
        videoRange: String? = nil,
        codecs: String? = nil,
        resolution: String? = nil,
        peakBitrate: String? = nil,
        atmosRendition: String? = nil,
        source: String = "unknown"
    ) {
        self.hdrType = hdrType
        self.audioFormat = audioFormat
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
        self.videoRange = videoRange
        self.codecs = codecs
        self.resolution = resolution
        self.peakBitrate = peakBitrate
        self.atmosRendition = atmosRendition
        self.source = source
    }
}

enum StreamQualityDetection {
    struct DetectedQuality: Sendable, Equatable {
        var hdrType: PlayerHDRType?
        var audioFormat: PlayerAudioFormat?
        var diagnostics: StreamQualityDiagnostics?
    }

    static func detect(from asset: AVAsset, manifestURL: URL? = nil) async -> DetectedQuality {
        if let manifestURL, manifestURL.pathExtension.lowercased() == "m3u8",
           let manifest = await detectFromHLSManifest(url: manifestURL) {
            let track = await detectFromAssetTracks(asset)
            return merge(manifest: manifest, track: track, manifestURL: manifestURL)
        }
        let track = await detectFromAssetTracks(asset)
        return DetectedQuality(
            hdrType: track.hdrType,
            audioFormat: track.audioFormat,
            diagnostics: track.diagnostics
        )
    }

    private static func merge(
        manifest: DetectedQuality,
        track: DetectedQuality,
        manifestURL: URL
    ) -> DetectedQuality {
        var diagnostics = manifest.diagnostics ?? StreamQualityDiagnostics(source: "hls-manifest")
        if let trackDiag = track.diagnostics {
            diagnostics.colorPrimaries = trackDiag.colorPrimaries ?? diagnostics.colorPrimaries
            diagnostics.colorTransfer = trackDiag.colorTransfer ?? diagnostics.colorTransfer
            if trackDiag.source == "avplayer-track" {
                diagnostics.source = "hls-manifest+avplayer-track"
            }
        }
        return DetectedQuality(
            hdrType: manifest.hdrType ?? track.hdrType,
            audioFormat: manifest.audioFormat ?? track.audioFormat,
            diagnostics: diagnostics
        )
    }

    private static func detectFromAssetTracks(_ asset: AVAsset) async -> DetectedQuality {
        let video = await detectVideoHDR(from: asset)
        let audio = await detectAtmos(from: asset)
        var primaries: String?
        var transfer: String?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let descriptions = try? await track.load(.formatDescriptions),
           let format = descriptions.first {
            let cmFormat = format as! CMFormatDescription
            primaries = colorPrimaries(cmFormat)
            transfer = colorTransfer(cmFormat)
        }
        let diagnostics = StreamQualityDiagnostics(
            hdrType: video,
            audioFormat: audio,
            colorPrimaries: primaries,
            colorTransfer: transfer,
            source: "avplayer-track"
        )
        return DetectedQuality(hdrType: video, audioFormat: audio, diagnostics: diagnostics)
    }

    static func detectFromHLSManifest(url: URL) async -> DetectedQuality? {
        guard let text = await fetchManifest(url) else { return nil }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let atmosRendition = parseAtmosAudioRendition(lines: lines)
        guard let best = parseBestHDRVariant(lines: lines) else {
            if atmosRendition != nil {
                return DetectedQuality(
                    audioFormat: .dolbyAtmos,
                    diagnostics: StreamQualityDiagnostics(
                        audioFormat: .dolbyAtmos,
                        atmosRendition: atmosRendition,
                        source: "hls-manifest"
                    )
                )
            }
            return nil
        }

        let hdrType = hdrTypeFromVariant(best)
        let bitrate = best.bandwidth > 0 ? String(format: "%.1f Mbps", Double(best.bandwidth) / 1_000_000) : nil
        let diagnostics = StreamQualityDiagnostics(
            hdrType: hdrType,
            audioFormat: atmosRendition != nil ? .dolbyAtmos : nil,
            colorPrimaries: best.videoRange == "PQ" ? "BT.2020 (manifest PQ)" : nil,
            colorTransfer: best.codecs.lowercased().contains("dvh1") ? "Dolby Vision PQ" : (best.videoRange == "PQ" ? "PQ (HDR10)" : nil),
            videoRange: best.videoRange,
            codecs: best.codecs,
            resolution: best.resolution,
            peakBitrate: bitrate,
            atmosRendition: atmosRendition,
            source: "hls-manifest"
        )
        return DetectedQuality(hdrType: hdrType, audioFormat: diagnostics.audioFormat, diagnostics: diagnostics)
    }

    private struct HLSVariantRow {
        var bandwidth: Int
        var videoRange: String
        var codecs: String
        var supplementalCodecs: String
        var resolution: String
        var hasHDR10PlusPath: Bool
    }

    private static func parseBestHDRVariant(lines: [String]) -> HLSVariantRow? {
        var bestPQDV: HLSVariantRow?
        var bestPQ: HLSVariantRow?
        var bestHLG: HLSVariantRow?

        for line in lines where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let attrs = parseM3U8Attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            guard let codecs = attrs["CODECS"] else { continue }
            let videoRange = (attrs["VIDEO-RANGE"] ?? "SDR").uppercased()
            let resolution = attrs["RESOLUTION"] ?? ""
            let pixels = pixelCount(resolution: resolution)
            let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
            let supplemental = attrs["SUPPLEMENTAL-CODECS"] ?? ""
            let row = HLSVariantRow(
                bandwidth: bandwidth,
                videoRange: videoRange,
                codecs: codecs,
                supplementalCodecs: supplemental,
                resolution: resolution,
                hasHDR10PlusPath: false
            )

            switch videoRange {
            case "PQ":
                if codecs.lowercased().contains("dvh1") {
                    if bestPQDV == nil || pixels > pixelCount(resolution: bestPQDV!.resolution)
                        || (pixels == pixelCount(resolution: bestPQDV!.resolution) && bandwidth > bestPQDV!.bandwidth) {
                        bestPQDV = row
                    }
                } else if codecs.lowercased().contains("hvc1") || codecs.lowercased().contains("hev1") {
                    if bestPQ == nil || pixels > pixelCount(resolution: bestPQ!.resolution)
                        || (pixels == pixelCount(resolution: bestPQ!.resolution) && bandwidth > bestPQ!.bandwidth) {
                        bestPQ = row
                    }
                }
            case "HLG":
                if bestHLG == nil || pixels > pixelCount(resolution: bestHLG!.resolution) {
                    bestHLG = row
                }
            default:
                continue
            }
        }

        let hasHDR10PlusBundle = lines.contains { $0.lowercased().contains("hdr10plus") }
        if var dv = bestPQDV {
            dv.hasHDR10PlusPath = hasHDR10PlusBundle
            return dv
        }
        return bestPQ ?? bestHLG
    }

    private static func hdrTypeFromVariant(_ variant: HLSVariantRow) -> PlayerHDRType? {
        let codecs = variant.codecs.lowercased()
        let supplemental = variant.supplementalCodecs.lowercased()
        if codecs.contains("dvh1") || supplemental.contains("dvh1") {
            if variant.hasHDR10PlusPath || supplemental.contains("db1p") || codecs.contains("hvc1.2.2") {
                return .dolbyVisionWithHDR10
            }
            return .dolbyVision
        }
        if variant.videoRange == "PQ" {
            if variant.hasHDR10PlusPath || codecs.contains("cdm4") {
                return .hdr10Plus
            }
            return .hdr10
        }
        if variant.videoRange == "HLG" {
            return .hlg
        }
        return nil
    }

    private static func parseAtmosAudioRendition(lines: [String]) -> String? {
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") {
            let lower = line.lowercased()
            if lower.contains("ec-3") || lower.contains("ec3"),
               lower.contains("joc") || lower.contains("atmos") {
                if let name = parseMediaName(line) {
                    return name
                }
                return "Dolby Atmos (E-AC-3 JOC)"
            }
        }
        return nil
    }

    private static func parseMediaName(_ line: String) -> String? {
        guard let range = line.range(of: "NAME=\"") else { return nil }
        let tail = line[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }

    private static func parseM3U8Attributes(_ input: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = #"([A-Z0-9-]+)=("([^"]*)"|[^,]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributes }
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        regex.enumerateMatches(in: input, range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: input),
                  let valueRange = Range(match.range(at: 2), in: input) else { return }
            var value = String(input[valueRange]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            attributes[String(input[keyRange])] = value
        }
        return attributes
    }

    private static func pixelCount(resolution: String) -> Int {
        let parts = resolution.uppercased().split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]) else { return 0 }
        return width * height
    }

    private static func fetchManifest(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func detectVideoHDR(from asset: AVAsset) async -> PlayerHDRType? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let format = descriptions.first else {
            return nil
        }
        let cmFormat = format as! CMFormatDescription

        if hasDolbyVisionSignal(cmFormat) {
            let transfer = normalizedExtensionString(colorTransfer(cmFormat))
            if transfer.contains("2084") || transfer.contains("pq") || transfer.contains("st2084") {
                return .dolbyVisionWithHDR10
            }
            return .dolbyVision
        }

        let primaries = normalizedExtensionString(colorPrimaries(cmFormat))
        let transfer = normalizedExtensionString(colorTransfer(cmFormat))
        let isWideGamut = primaries.contains("2020") || primaries.contains("bt2020")
            || primaries.contains("itu_r_2020")
        guard isWideGamut else { return nil }

        if transfer.contains("hlg") || transfer.contains("2100") {
            return .hlg
        }
        if transfer.contains("2084") || transfer.contains("pq") || transfer.contains("st2084") {
            return .hdr10
        }
        if masteringDisplayPresent(cmFormat) {
            return .hdr
        }
        return nil
    }

    private static func detectAtmos(from asset: AVAsset) async -> PlayerAudioFormat? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return nil }
        for track in tracks {
            guard let descriptions = try? await track.load(.formatDescriptions) else { continue }
            for description in descriptions {
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description as! CMAudioFormatDescription) else {
                    continue
                }
                let formatID = asbd.pointee.mFormatID
                let channels = Int(asbd.pointee.mChannelsPerFrame)
                if formatID == kAudioFormatEnhancedAC3, channels >= 6 {
                    return .dolbyAtmos
                }
            }
        }
        return nil
    }

    private static func normalizedExtensionString(_ value: String?) -> String {
        value?.lowercased() ?? ""
    }

    private static func colorPrimaries(_ format: CMFormatDescription) -> String? {
        extensionString(format, key: kCMFormatDescriptionExtension_ColorPrimaries)
    }

    private static func colorTransfer(_ format: CMFormatDescription) -> String? {
        extensionString(format, key: kCMFormatDescriptionExtension_TransferFunction)
    }

    private static func extensionString(_ format: CMFormatDescription, key: CFString) -> String? {
        guard let value = CMFormatDescriptionGetExtension(format, extensionKey: key) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return "\(value)"
    }

    private static func masteringDisplayPresent(_ format: CMFormatDescription) -> Bool {
        CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume
        ) != nil
    }

    private static func hasDolbyVisionSignal(_ format: CMFormatDescription) -> Bool {
        if let atoms = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] {
            for key in atoms.keys where key.lowercased().contains("dovi") || key.lowercased().contains("dvhe") {
                return true
            }
        }
        let probe = "\(format)".lowercased()
        return probe.contains("dolby vision") || probe.contains("dovi") || probe.contains("dvhe")
    }
}
