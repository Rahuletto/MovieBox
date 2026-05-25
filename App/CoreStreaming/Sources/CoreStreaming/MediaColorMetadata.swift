import Foundation

// MARK: - HDR / color side data (ffprobe → playback verification)

public struct MasteringDisplayMetadata: Sendable, Equatable {
    public let redX: Double
    public let redY: Double
    public let greenX: Double
    public let greenY: Double
    public let blueX: Double
    public let blueY: Double
    public let whiteX: Double
    public let whiteY: Double
    public let minLuminance: Double
    public let maxLuminance: Double
}

public struct ContentLightLevel: Sendable, Equatable {
    /// MaxCLL (cd/m²)
    public let maxContent: Int
    /// MaxFALL (cd/m²)
    public let maxFrameAverage: Int
}

public struct DolbyVisionConfig: Sendable, Equatable {
    public let profile: Int?
    public let level: Int?
    public let rpuPresent: Bool

    public init(profile: Int?, level: Int?, rpuPresent: Bool) {
        self.profile = profile
        self.level = level
        self.rpuPresent = rpuPresent
    }
}

public struct HDR10PlusMetadata: Sendable, Equatable {
    public let present: Bool
}

public struct VideoColorMetadata: Sendable, Equatable {
    public let colorPrimaries: String?
    public let colorTransfer: String?
    public let colorSpace: String?
    public let dynamicRange: DynamicRange
    public let masteringDisplay: MasteringDisplayMetadata?
    public let contentLightLevel: ContentLightLevel?
    public let dolbyVision: DolbyVisionConfig?
    public let hdr10Plus: HDR10PlusMetadata

    public var hasMasteringDisplay: Bool { masteringDisplay != nil }
    public var hasContentLightLevel: Bool { contentLightLevel != nil }
    public var hasHDR10Plus: Bool { hdr10Plus.present }
}

public struct AtmosAudioInfo: Sendable, Equatable {
    public let codecName: String
    public let channelCount: Int?
    public let channelLayout: String?
    public let hasAtmosMetadata: Bool

    /// Multichannel E-AC-3 or explicit Atmos/JOC — eligible for system Spatial Audio / HDMI Atmos passthrough.
    public var isSpatialAudioEligible: Bool {
        guard codecName == "eac3" else { return false }
        if hasAtmosMetadata { return true }
        guard let channelCount else { return false }
        return channelCount > 2
    }
}

// MARK: - ffprobe side_data parsing

enum SideDataParser {
    static func videoColorMetadata(
        colorPrimaries: String?,
        colorTransfer: String?,
        colorSpace: String?,
        sideDataList: [FFProbeSideDataEntry]?
    ) -> VideoColorMetadata {
        var mastering: MasteringDisplayMetadata?
        var cll: ContentLightLevel?
        var dovi: DolbyVisionConfig?
        var hdr10Plus = HDR10PlusMetadata(present: false)

        for entry in sideDataList ?? [] {
            let type = entry.sideDataType?.lowercased() ?? ""
            switch type {
            case let t where t.contains("mastering display metadata"):
                if let parsed = parseMasteringDisplay(entry) {
                    mastering = parsed
                }
            case let t where t.contains("content light level metadata"):
                if let parsed = parseContentLightLevel(entry) {
                    cll = parsed
                }
            case let t where t.contains("dovi configuration") || t.contains("dolby vision"):
                if let parsed = parseDolbyVision(entry) {
                    dovi = parsed
                }
            case let t where t.contains("smpte2094") || t.contains("hdr dynamic metadata"):
                hdr10Plus = HDR10PlusMetadata(present: true)
            default:
                break
            }
        }

        let dynamicRange = classifyDynamicRange(
            colorPrimaries: colorPrimaries,
            colorTransfer: colorTransfer,
            colorSpace: colorSpace,
            hasDolbyVision: dovi != nil,
            hasHDR10Plus: hdr10Plus.present,
            sideDataSearch: sideDataList?.flatMap(\.searchableText).joined(separator: " ") ?? ""
        )

        return VideoColorMetadata(
            colorPrimaries: colorPrimaries,
            colorTransfer: colorTransfer,
            colorSpace: colorSpace,
            dynamicRange: dynamicRange,
            masteringDisplay: mastering,
            contentLightLevel: cll,
            dolbyVision: dovi,
            hdr10Plus: hdr10Plus
        )
    }

    static func atmosAudioInfo(
        codecName: String,
        channels: Int?,
        channelLayout: String?,
        sideDataList: [FFProbeSideDataEntry]?,
        tagsSearch: String
    ) -> AtmosAudioInfo {
        let sideSearch = sideDataList?.flatMap(\.searchableText).joined(separator: " ").lowercased() ?? ""
        let haystack = "\(tagsSearch) \(sideSearch)".lowercased()
        let hasAtmos = haystack.contains("atmos")
            || haystack.contains("joc")
            || haystack.contains("joint object coding")
        return AtmosAudioInfo(
            codecName: codecName,
            channelCount: channels,
            channelLayout: channelLayout,
            hasAtmosMetadata: hasAtmos
        )
    }

    private static func classifyDynamicRange(
        colorPrimaries: String?,
        colorTransfer: String?,
        colorSpace: String?,
        hasDolbyVision: Bool,
        hasHDR10Plus: Bool,
        sideDataSearch: String
    ) -> DynamicRange {
        let haystack = sideDataSearch.lowercased()
        if hasDolbyVision
            || haystack.contains("dolby vision")
            || haystack.contains("dovi")
            || haystack.contains("dv profile") {
            return .dolbyVision
        }
        if hasHDR10Plus
            || haystack.contains("hdr10+")
            || haystack.contains("smpte2094") {
            return .hdr10Plus
        }
        if colorTransfer == "arib-std-b67" { return .hlg }
        if colorTransfer == "smpte2084" { return .hdr10 }
        return .sdr
    }

    private static func parseMasteringDisplay(_ entry: FFProbeSideDataEntry) -> MasteringDisplayMetadata? {
        guard let redX = entry.double("red_x"),
              let redY = entry.double("red_y"),
              let greenX = entry.double("green_x"),
              let greenY = entry.double("green_y"),
              let blueX = entry.double("blue_x"),
              let blueY = entry.double("blue_y"),
              let whiteX = entry.double("white_x"),
              let whiteY = entry.double("white_y"),
              let minLum = entry.double("min_luminance"),
              let maxLum = entry.double("max_luminance") else {
            return nil
        }
        return MasteringDisplayMetadata(
            redX: redX, redY: redY,
            greenX: greenX, greenY: greenY,
            blueX: blueX, blueY: blueY,
            whiteX: whiteX, whiteY: whiteY,
            minLuminance: minLum,
            maxLuminance: maxLum
        )
    }

    private static func parseContentLightLevel(_ entry: FFProbeSideDataEntry) -> ContentLightLevel? {
        guard let maxContent = entry.int("max_content"),
              let maxAverage = entry.int("max_average") else {
            return nil
        }
        return ContentLightLevel(maxContent: maxContent, maxFrameAverage: maxAverage)
    }

    private static func parseDolbyVision(_ entry: FFProbeSideDataEntry) -> DolbyVisionConfig? {
        let profile = entry.int("dv_profile") ?? entry.int("profile")
        let level = entry.int("dv_level") ?? entry.int("level")
        let rpu = entry.string("rpu_present_flag") == "1"
            || entry.int("rpu_present_flag") == 1
            || entry.sideDataType?.lowercased().contains("dovi") == true
        if profile == nil, level == nil, !rpu { return nil }
        return DolbyVisionConfig(profile: profile, level: level, rpuPresent: rpu)
    }
}

/// One ffprobe `side_data_list` element with typed accessors.
struct FFProbeSideDataEntry: Decodable, Sendable {
    let sideDataType: String?
    private let fields: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FFProbeFlexibleCodingKey.self)
        sideDataType = try container.decodeIfPresent(String.self, forKey: FFProbeFlexibleCodingKey("side_data_type"))
        var parsed: [String: String] = [:]
        for key in container.allKeys where key.stringValue != "side_data_type" {
            if let value = try? container.decode(String.self, forKey: key) {
                parsed[key.stringValue] = value
            } else if let value = try? container.decode(Int.self, forKey: key) {
                parsed[key.stringValue] = String(value)
            } else if let value = try? container.decode(Double.self, forKey: key) {
                parsed[key.stringValue] = String(value)
            }
        }
        fields = parsed
    }

    var searchableText: [String] {
        var values = [sideDataType].compactMap { $0 }
        values.append(contentsOf: fields.values)
        return values
    }

    func string(_ key: String) -> String? { fields[key] }
    func int(_ key: String) -> Int? { fields[key].flatMap(Int.init) }
    func double(_ key: String) -> Double? { fields[key].flatMap(Double.init) }
}

struct FFProbeFlexibleCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
