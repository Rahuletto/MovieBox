import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import MoviePlayerEngine
import SwiftUI


public enum PlayerHDRType: String, Sendable, Codable {
    case hdr = "HDR"
    case hdr10 = "HDR10"
    case hdr10Plus = "HDR10+"
    case hlg = "HLG"
    case dolbyVision = "Dolby Vision"
    case dolbyVisionWithHDR10 = "DV-HDR10"
}

public struct PlayerEpisode: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let episodeNumber: Int
    public let seasonNumber: Int
    public let url: URL
    public let subtitleURL: URL?
    
    public init(id: String, title: String, episodeNumber: Int, seasonNumber: Int, url: URL, subtitleURL: URL? = nil) {
        self.id = id
        self.title = title
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.url = url
        self.subtitleURL = subtitleURL
    }
}
