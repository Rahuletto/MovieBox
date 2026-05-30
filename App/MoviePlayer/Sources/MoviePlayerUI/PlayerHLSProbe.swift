import Foundation

struct HLSStatsProbe {
    let quality: String?
    let bitrate: String?
    let codec: String?
    let variants: [HLSVariant]
}

struct HLSVariant {
    let bandwidth: Int
    let quality: String?
    let codec: String?
}
