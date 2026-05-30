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

    public var allowTranscodeFallback: Bool {
        get { allowTranscodeFallbackStorage }
        set { allowTranscodeFallbackStorage = newValue }
    }

    private var strictHDRValidationStorage = false
    private var allowTranscodeFallbackStorage = true

    public init(remuxService: RemuxService = RemuxService()) {
        self.remuxService = remuxService
    }

    public var playbackPreparePolicy: PlaybackPreparePolicy {
        PlaybackPreparePolicy(allowTranscodeFallback: allowTranscodeFallbackStorage)
    }

    public func setStrictHDRValidation(_ enabled: Bool) async {
        strictHDRValidationStorage = enabled
        await remuxService.setStrictHDRValidation(enabled)
    }

    public func probe(inputURL: URL) async throws -> MediaProbe {
        try await remuxService.probe(inputURL: inputURL)
    }

    public func prepareForPlayback(inputURL: URL, cacheKey: String) async throws -> PlaybackPrepareResult {
        await remuxService.setStrictHDRValidation(strictHDRValidationStorage)
        return try await remuxService.prepareForPlayback(
            inputURL: inputURL,
            cacheKey: cacheKey,
            policy: playbackPreparePolicy
        )
    }

    public func prepareStreamingForPlayback(inputURL: URL, cacheKey: String) async throws -> PlaybackPrepareResult {
        await remuxService.setStrictHDRValidation(strictHDRValidationStorage)
        return try await remuxService.prepareStreamingForPlayback(
            inputURL: inputURL,
            cacheKey: cacheKey,
            policy: playbackPreparePolicy
        )
    }

    public func remuxMKVToHLS(inputURL: URL, cacheKey: String) async throws -> RemuxResult {
        let prepared = try await prepareForPlayback(inputURL: inputURL, cacheKey: cacheKey)
        if let remuxResult = prepared.remuxResult {
            return remuxResult
        }
        return RemuxResult(
            playlistURL: prepared.playbackURL,
            outputDirectory: prepared.playbackURL.deletingLastPathComponent(),
            state: .completed,
            durationSeconds: prepared.durationSeconds,
            preparationMode: .nativePassthrough
        )
    }

    public func remuxStreamingMKVToHLS(inputURL: URL, cacheKey: String) async throws -> RemuxResult {
        let prepared = try await prepareStreamingForPlayback(inputURL: inputURL, cacheKey: cacheKey)
        if let remuxResult = prepared.remuxResult {
            return remuxResult
        }
        return RemuxResult(
            playlistURL: prepared.playbackURL,
            outputDirectory: prepared.playbackURL.deletingLastPathComponent(),
            state: .playable,
            durationSeconds: prepared.durationSeconds,
            preparationMode: .nativePassthrough
        )
    }

    public func cancelRemux() async {
        await remuxService.stopAll()
    }

    public func estimatedStreamingHLSDuration(cacheKey: String) async -> Double {
        await remuxService.estimatedStreamingHLSDuration(cacheKey: cacheKey)
    }

    public func restartStreamingRemux(
        inputURL: URL,
        cacheKey: String,
        seekSeconds: Double
    ) async throws -> RemuxResult {
        try await remuxService.restartStreamingRemux(
            inputURL: inputURL,
            cacheKey: cacheKey,
            seekSeconds: seekSeconds
        )
    }

    public func applyRemuxPlaybackSignals(_ remux: RemuxResult, to playerState: PlayerState) {
        playerState.updatePlaybackQualityWarning(remux.metadataValidationWarning)
    }

    public func playbackHDR(from remux: RemuxResult?) -> PlayerHDRType? {
        guard let remux,
              remux.preparationMode != .transcodeHLS,
              remux.metadataValidationPassed,
              let color = remux.verifiedVideoColor else {
            return nil
        }
        return Self.playerHDRType(from: color)
    }

    public func playbackAudio(from remux: RemuxResult?) -> PlayerAudioFormat? {
        guard let remux,
              remux.preparationMode != .transcodeHLS,
              remux.metadataValidationPassed,
              let atmos = remux.verifiedAtmos,
              atmos.hasAtmosMetadata || atmos.isSpatialAudioEligible else {
            return nil
        }
        return .dolbyAtmos
    }

    public func usesVerifiedBadges(prepare: PlaybackPrepareResult?, remux: RemuxResult?) -> Bool {
        prepare?.mode != .transcodeHLS && remux?.preparationMode != .transcodeHLS
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
