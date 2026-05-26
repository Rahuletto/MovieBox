@preconcurrency import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


@MainActor
extension PlayerState {
    func applyStreamQualityBadgesFromAsset(item: AVPlayerItem) async {
        let manifestURL = (item.asset as? AVURLAsset)?.url
        var detected = StreamQualityDetection.DetectedQuality()
        for attempt in 0..<4 {
            detected = await StreamQualityDetection.detect(from: item.asset, manifestURL: manifestURL)
            if detected.hdrType != nil || detected.audioFormat != nil {
                break
            }
            if attempt < 3 {
                try? await Task.sleep(for: .milliseconds(350))
            }
        }

        streamQualityDiagnostics = detected.diagnostics

        if !qualityBadgesLockedFromPrepare {
            if let streamHDR = detected.hdrType, streamHDR != hdrType {
                hdrType = streamHDR
            }
            if let streamAtmos = detected.audioFormat, streamAtmos != audioFormat {
                audioFormat = streamAtmos
            }
            // Pill is one-shot per load; badge values may refine as HLS/track probing updates.
            presentQualityBadgesHUDPillIfNeeded()
        }

        let sourceLabel = manifestURL?.absoluteString ?? title
        PlaybackLog.log(
            "[HDR] stream detect hdr=\(detected.hdrType?.rawValue ?? "none") atmos=\(detected.audioFormat != nil) locked=\(qualityBadgesLockedFromPrepare) playerHDR=\(hdrType?.rawValue ?? "none") source=\(sourceLabel)"
        )
    }

    /// Probes HLS manifest + AVPlayer tracks (used by Apple reference streams in Downloads).
    public func refreshStreamQualityBadges(manifestURL: URL?) async {
        guard let item = player.currentItem else { return }
        let url = manifestURL ?? (item.asset as? AVURLAsset)?.url
        let detected = await StreamQualityDetection.detect(from: item.asset, manifestURL: url)
        streamQualityDiagnostics = detected.diagnostics
        if !qualityBadgesLockedFromPrepare {
            hdrType = detected.hdrType
            audioFormat = detected.audioFormat
        }
    }

}
