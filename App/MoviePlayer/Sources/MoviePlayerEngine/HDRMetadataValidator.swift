import Foundation

public struct HDRValidationIssue: Sendable, Equatable {
    public let field: String
    public let message: String
}

public struct HDRValidationResult: Sendable, Equatable {
    public let passed: Bool
    public let issues: [HDRValidationIssue]
    public let warnings: [HDRValidationIssue]

    public static let ok = HDRValidationResult(passed: true, issues: [], warnings: [])
}

public enum HDRMetadataValidator {
    /// Strict gate: source HDR/DV/Atmos signaling must survive remux for AVPlayer tone-mapping / HDMI passthrough.
    public static func validate(
        sourceVideo: VideoColorMetadata?,
        sourceAtmos: AtmosAudioInfo?,
        outputVideo: VideoColorMetadata?,
        outputAtmos: AtmosAudioInfo?,
        plan: RemuxPlan
    ) -> HDRValidationResult {
        var issues: [HDRValidationIssue] = []
        var warnings: [HDRValidationIssue] = []

        guard plan.decision != .unsupported,
              plan.decision != .nativePassthrough,
              !plan.decision.isTranscode else { return .ok }

        if let sourceVideo, let outputVideo {
            issues.append(contentsOf: validateVideo(source: sourceVideo, output: outputVideo))
            if sourceVideo.hasHDR10Plus, !outputVideo.hasHDR10Plus {
                warnings.append(HDRValidationIssue(
                    field: "hdr10plus",
                    message: "HDR10+ dynamic metadata may not be active on all macOS outputs; bitstream signaling was checked."
                ))
            }
        } else if sourceVideo != nil, outputVideo == nil {
            issues.append(HDRValidationIssue(field: "video", message: "No video stream in remux output probe."))
        }

        if let sourceAtmos, let outputAtmos {
            issues.append(contentsOf: validateAtmos(source: sourceAtmos, output: outputAtmos))
        } else if sourceAtmos != nil, outputAtmos == nil {
            issues.append(HDRValidationIssue(field: "audio", message: "No compatible audio stream in remux output probe."))
        }

        return HDRValidationResult(
            passed: issues.isEmpty,
            issues: issues,
            warnings: warnings
        )
    }

    private static func validateVideo(
        source: VideoColorMetadata,
        output: VideoColorMetadata
    ) -> [HDRValidationIssue] {
        var issues: [HDRValidationIssue] = []

        if source.dynamicRange == .sdr { return [] }

        if source.colorTransfer != nil, source.colorTransfer != output.colorTransfer {
            issues.append(HDRValidationIssue(
                field: "color_transfer",
                message: "color_transfer changed (\(source.colorTransfer ?? "nil") → \(output.colorTransfer ?? "nil"))."
            ))
        }
        if source.colorPrimaries != nil, source.colorPrimaries != output.colorPrimaries {
            issues.append(HDRValidationIssue(
                field: "color_primaries",
                message: "color_primaries changed (\(source.colorPrimaries ?? "nil") → \(output.colorPrimaries ?? "nil"))."
            ))
        }

        switch source.dynamicRange {
        case .hlg:
            if output.colorTransfer != "arib-std-b67" {
                issues.append(HDRValidationIssue(field: "hlg", message: "HLG transfer (arib-std-b67) not preserved."))
            }
        case .hdr10, .hdr10Plus:
            let pqPreserved = output.colorTransfer == "smpte2084"
                || output.dynamicRange == .dolbyVision
                || output.dynamicRange == .hdr10
                || output.dynamicRange == .hdr10Plus
            if !pqPreserved {
                issues.append(HDRValidationIssue(field: "hdr10", message: "PQ transfer (smpte2084) not preserved."))
            }
            if source.hasMasteringDisplay, !output.hasMasteringDisplay {
                issues.append(HDRValidationIssue(field: "mastering", message: "Mastering display metadata stripped during remux."))
            }
            if source.hasContentLightLevel, !output.hasContentLightLevel {
                issues.append(HDRValidationIssue(field: "cll", message: "Content light level (MaxCLL/MaxFALL) stripped during remux."))
            }
        case .dolbyVision:
            if output.dolbyVision == nil {
                issues.append(HDRValidationIssue(field: "dolby_vision", message: "Dolby Vision configuration stripped during remux."))
            } else if let sourceProfile = source.dolbyVision?.profile,
                      let outputProfile = output.dolbyVision?.profile,
                      sourceProfile != outputProfile {
                issues.append(HDRValidationIssue(
                    field: "dv_profile",
                    message: "Dolby Vision profile changed (\(sourceProfile) → \(outputProfile))."
                ))
            }
            if source.hasMasteringDisplay, !output.hasMasteringDisplay {
                issues.append(HDRValidationIssue(field: "mastering", message: "Mastering display metadata stripped during remux."))
            }
            if source.hasContentLightLevel, !output.hasContentLightLevel {
                issues.append(HDRValidationIssue(field: "cll", message: "Content light level stripped during remux."))
            }
        case .sdr:
            break
        }

        return issues
    }

    private static func validateAtmos(
        source: AtmosAudioInfo,
        output: AtmosAudioInfo
    ) -> [HDRValidationIssue] {
        guard source.hasAtmosMetadata || source.isSpatialAudioEligible else { return [] }
        var issues: [HDRValidationIssue] = []

        if output.codecName != "eac3" {
            issues.append(HDRValidationIssue(
                field: "atmos_codec",
                message: "Atmos track must remain E-AC-3 (eac3); got \(output.codecName)."
            ))
        }
        if source.hasAtmosMetadata, !output.hasAtmosMetadata {
            issues.append(HDRValidationIssue(field: "atmos_metadata", message: "Dolby Atmos/JOC metadata stripped during remux."))
        }
        if let sourceChannels = source.channelCount,
           let outputChannels = output.channelCount,
           sourceChannels > 2, outputChannels < sourceChannels {
            issues.append(HDRValidationIssue(
                field: "channels",
                message: "Channel count reduced (\(sourceChannels) → \(outputChannels)); Spatial Audio / surround may be lost."
            ))
        }
        return issues
    }
}
