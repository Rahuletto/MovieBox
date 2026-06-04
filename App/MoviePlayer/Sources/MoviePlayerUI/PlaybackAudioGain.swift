import Accelerate
import AVFoundation
import MediaToolbox

final class PlaybackAudioGainStorage: @unchecked Sendable {
    var gain: Float = 1
    var processesFloat32 = true
}

@MainActor
final class PlaybackAudioGainController {
    private let storage = PlaybackAudioGainStorage()
    private var installedItemID: ObjectIdentifier?

    func setGain(_ gain: Float) {
        storage.gain = max(0, gain)
    }

    func hasTap(for item: AVPlayerItem?) -> Bool {
        guard let item else { return false }
        return installedItemID == ObjectIdentifier(item)
    }

    func reset(for item: AVPlayerItem?) {
        if let item, installedItemID == ObjectIdentifier(item) {
            item.audioMix = nil
        }
        installedItemID = nil
    }

    func clear() {
        installedItemID = nil
    }

    func updateLiveVolume(on player: AVPlayer, useProcessingTap: Bool) {
        let gain = storage.gain
        if useProcessingTap, hasTap(for: player.currentItem) {
            player.volume = 1
            return
        }
        player.volume = min(4, gain)
    }

    func configure(for player: AVPlayer, useProcessingTap: Bool) async {
        guard let item = player.currentItem else { return }

        if useProcessingTap {
            if hasTap(for: item) {
                player.volume = 1
                return
            }
            if let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
               installTap(on: item, track: track) {
                player.volume = 1
                return
            }
        }

        item.audioMix = nil
        installedItemID = nil
        player.volume = min(4, storage.gain)
    }

    @discardableResult
    private func installTap(on item: AVPlayerItem, track: AVAssetTrack) -> Bool {
        var tap: MTAudioProcessingTap?
        let clientInfo = Unmanaged.passUnretained(storage).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: Self.tapInit,
            finalize: Self.tapFinalize,
            prepare: Self.tapPrepare,
            unprepare: Self.tapUnprepare,
            process: Self.tapProcess
        )
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )
        guard status == noErr, let tapRef = tap else { return false }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tapRef
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
        installedItemID = ObjectIdentifier(item)
        return true
    }

    private static let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
        tapStorageOut.pointee = clientInfo
    }

    private static let tapFinalize: MTAudioProcessingTapFinalizeCallback = { _ in }

    private static let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
        let format = processingFormat.pointee
        let storage = storage(from: tap)
        storage.processesFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    }

    private static let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

    private static let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
        var localFlags = flagsOut.pointee
        var localFrames = numberFramesOut.pointee
        let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, &localFlags, nil, &localFrames)
        guard status == noErr else { return }
        flagsOut.pointee = localFlags
        numberFramesOut.pointee = localFrames

        let storage = storage(from: tap)
        let gain = storage.gain
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
        if storage.processesFloat32 {
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(localFrames)
                var scalar = gain
                vDSP_vsmul(data, 1, &scalar, data, 1, vDSP_Length(count))
            }
        } else {
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Int16.self) else { continue }
                let count = Int(localFrames)
                for index in 0..<count {
                    let scaled = Float(data[index]) * gain
                    data[index] = Int16(max(-32_768, min(32_767, scaled)))
                }
            }
        }
    }

    private static func storage(from tap: MTAudioProcessingTap) -> PlaybackAudioGainStorage {
        Unmanaged<PlaybackAudioGainStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }
}
