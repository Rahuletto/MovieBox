import Foundation
import MoviePlayerEngine
import MoviePlayerUI

/// Facade for reusable AVPlayer UI + MKV/HLS remux with HDR/DV/Atmos verification.
@MainActor
public final class MoviePlayerSession {
    private let remuxService: RemuxService

    public var strictHDRValidation: Bool {
        get { strictHDRValidationStorage }
        set { strictHDRValidationStorage = newValue }
    }

    private var strictHDRValidationStorage = false

    public init(remuxService: RemuxService = RemuxService()) {
        self.remuxService = remuxService
    }

    public func setStrictHDRValidation(_ enabled: Bool) async {
        strictHDRValidationStorage = enabled
        await remuxService.setStrictHDRValidation(enabled)
    }

    public func probe(inputURL: URL) async throws -> MediaProbe {
        try await remuxService.probe(inputURL: inputURL)
    }

    public func remuxMKVToHLS(inputURL: URL, cacheKey: String) async throws -> RemuxResult {
        await remuxService.setStrictHDRValidation(strictHDRValidationStorage)
        return try await remuxService.remuxMKVToHLS(inputURL: inputURL, cacheKey: cacheKey)
    }

    public func remuxStreamingMKVToHLS(inputURL: URL, cacheKey: String) async throws -> RemuxResult {
        await remuxService.setStrictHDRValidation(strictHDRValidationStorage)
        return try await remuxService.remuxStreamingMKVToHLS(inputURL: inputURL, cacheKey: cacheKey)
    }

    public func cancelRemux() async {
        await remuxService.stopAll()
    }

    public func applyRemuxPlaybackSignals(_ remux: RemuxResult, to playerState: PlayerState) {
        playerState.updatePlaybackQualityWarning(remux.metadataValidationWarning)
    }

    public func playbackHDR(from remux: RemuxResult?) -> PlayerHDRType? {
        guard let remux, remux.metadataValidationPassed, let color = remux.verifiedVideoColor else {
            return nil
        }
        return Self.playerHDRType(from: color)
    }

    public func playbackAudio(from remux: RemuxResult?) -> PlayerAudioFormat? {
        guard let remux,
              remux.metadataValidationPassed,
              let atmos = remux.verifiedAtmos,
              atmos.hasAtmosMetadata || atmos.isSpatialAudioEligible else {
            return nil
        }
        return .dolbyAtmos
    }

    public static func playerHDRType(from color: VideoColorMetadata) -> PlayerHDRType? {
        switch color.dynamicRange {
        case .sdr: return nil
        case .hdr10: return .hdr10
        case .hdr10Plus: return .hdr10Plus
        case .hlg: return .hlg
        case .dolbyVision:
            if color.colorTransfer == "smpte2084" || color.hasHDR10Plus {
                return .dolbyVisionWithHDR10
            }
            return .dolbyVision
        }
    }
}
