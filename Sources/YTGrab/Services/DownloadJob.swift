import Foundation
import Observation

enum JobState: String, Sendable {
    case queued, running, paused, stopped, failed, done, cancelled
    /// Was queued/running/paused when the app last quit. Restored from
    /// history; Resume re-spawns with --continue on the kept .part files.
    case interrupted
}

enum JobPhase: String, Sendable {
    case preparing, fetching, downloading, processing
}

@Observable
final class DownloadJob: Identifiable {
    let id: UUID
    var title: String
    let url: String
    let quality: VideoQuality
    /// Snapshot of the container setting in effect at enqueue time.
    var container: VideoContainer = .mp4
    /// Directory captured at enqueue so resume/restart target the same
    /// folder even if the user later changes the save directory.
    var outputDirectory = ""
    let createdAt: Date
    var finishedAt: Date?
    var state: JobState = .queued
    var phase: JobPhase?
    /// Short qualifier for the phase line ("Downloading webpage",
    /// "Merging…"); nil falls back to the generic phase text.
    var phaseDetail: String?
    var percent: Double = 0
    var speedText = ""
    var etaText = ""
    var sizeText = ""
    /// "stream 2/3" when the download spans multiple destinations.
    var streamText = ""
    var errorText: String?
    var finalPath: String?

    init(title: String, url: String, quality: VideoQuality) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.quality = quality
        self.createdAt = Date()
    }

    /// Rebuilds a job from its persisted history record.
    init(record: HistoryRecord) {
        self.id = record.id
        self.title = record.title
        self.url = record.videoURL
        self.quality = VideoQuality(rawValue: record.quality) ?? .best
        self.container = VideoContainer(rawValue: record.container) ?? .mp4
        self.outputDirectory = record.outputDirectory
        self.createdAt = record.createdAt
        self.finishedAt = record.finishedAt
        self.state = JobState(rawValue: record.state) ?? .failed
        self.percent = record.progress
        self.sizeText = record.totalSize
        self.errorText = record.errorText
        self.finalPath = record.finalPath
    }

    var isResumable: Bool {
        state == .failed || state == .stopped || state == .cancelled
            || state == .interrupted
    }

    /// Case-insensitive substring match for the history search field.
    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || url.localizedCaseInsensitiveContains(query)
            || (finalPath?.localizedCaseInsensitiveContains(query) ?? false)
    }

    var statusLine: String {
        switch state {
        case .queued: return "Queued"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        case .failed: return errorText.map { "Failed: \($0)" } ?? "Failed"
        case .running:
            switch phase {
            case .preparing:
                return phaseDetail.map { "Preparing · \($0)" }
                    ?? "Preparing…"
            case .fetching: return "Fetching formats"
            case .processing: return phaseDetail ?? "Processing…"
            case .downloading, .none: return "Downloading…"
            }
        }
    }
}
