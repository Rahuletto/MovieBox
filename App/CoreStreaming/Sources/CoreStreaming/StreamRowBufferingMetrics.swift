import Foundation

public struct StreamRowBufferingMetrics: Equatable, Sendable {
    public let progress: Double
    public let peerCount: Int
    public let transferringPeerCount: Int
    public let downloadSpeed: Double
    public let verifiedHeadBytes: Int64
    public let tailVerified: Int
    public let tailTotal: Int
    public let needsTailProbe: Bool
    public let indexProbeLabel: String
    public let isReady: Bool
    public let isPreparing: Bool
    public let failedMessage: String?

    public init(
        progress: Double,
        peerCount: Int,
        transferringPeerCount: Int,
        downloadSpeed: Double,
        verifiedHeadBytes: Int64,
        tailVerified: Int,
        tailTotal: Int,
        needsTailProbe: Bool,
        indexProbeLabel: String,
        isReady: Bool,
        isPreparing: Bool,
        failedMessage: String?
    ) {
        self.progress = progress
        self.peerCount = peerCount
        self.transferringPeerCount = transferringPeerCount
        self.downloadSpeed = downloadSpeed
        self.verifiedHeadBytes = verifiedHeadBytes
        self.tailVerified = tailVerified
        self.tailTotal = tailTotal
        self.needsTailProbe = needsTailProbe
        self.indexProbeLabel = indexProbeLabel
        self.isReady = isReady
        self.isPreparing = isPreparing
        self.failedMessage = failedMessage
    }
}
