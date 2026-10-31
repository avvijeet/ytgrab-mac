import Foundation
import Observation

enum JobState: String, Sendable {
    case queued, running, paused, stopped, failed, done, cancelled
}

enum JobPhase: String, Sendable {
    case preparing, downloading, processing
}

@Observable
final class DownloadJob: Identifiable {
    let id = UUID()
    var title: String
    let url: String
    let quality: VideoQuality
    var state: JobState = .queued
    var phase: JobPhase?
    var percent: Double = 0
    var speedText = ""
    var etaText = ""
    var sizeText = ""
    var errorText: String?
    var finalPath: String?

    init(title: String, url: String, quality: VideoQuality) {
        self.title = title
        self.url = url
        self.quality = quality
    }

    var isResumable: Bool {
        state == .failed || state == .stopped || state == .cancelled
    }

    var statusLine: String {
        switch state {
        case .queued: return "Queued"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .failed: return errorText.map { "Failed: \($0)" } ?? "Failed"
        case .running:
            switch phase {
            case .preparing: return "Preparing…"
            case .processing: return "Processing…"
            case .downloading, .none: return "Downloading…"
            }
        }
    }
}
