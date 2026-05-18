import CoreStorage
import SwiftUI

extension DownloadState {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch self {
        case .downloading: .blue
        case .completed: .green
        case .paused: .orange
        case .failed: .red
        case .queued: .secondary
        }
    }
}
